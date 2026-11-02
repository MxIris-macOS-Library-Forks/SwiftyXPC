#if os(macOS) || targetEnvironment(macCatalyst)
//
//  ListenerHandlerTests.swift
//
//  Which handler answers a message on a connection a listener accepted. Every
//  test here runs against an anonymous listener in this process, so none of
//  them needs the launchd helper the other suites load.
//

import XCTest
@testable import SwiftyXPC

final class ListenerHandlerTests: XCTestCase {
    private struct NoReply: Error {}

    /// Sends `request` and waits for the reply, cancelling the connection
    /// after `seconds`: a message no handler answers is never replied to, and
    /// would otherwise keep the test waiting forever.
    private func send(
        _ connection: XPCConnection,
        name: String,
        request: String,
        timeoutSeconds seconds: UInt64 = 5
    ) async throws -> String {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            connection.cancel()
        }
        defer { watchdog.cancel() }
        return try await connection.sendMessage(name: name, request: request)
    }

    private func makeListener() throws -> SwiftyXPC.XPCListener {
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        listener.errorHandler = { _, _ in }
        return listener
    }

    private func connect(to listener: SwiftyXPC.XPCListener) throws -> XPCConnection {
        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(listener.endpoint))
        connection.errorHandler = { _, _ in }
        connection.activate()
        return connection
    }

    func testHandlerSetAfterAcceptReachesTheAcceptedConnection() async throws {
        let listener = try self.makeListener()
        listener.setMessageHandler(name: "early") { (_: XPCConnection, request: String) -> String in
            "early \(request)"
        }
        listener.activate()
        let connection = try self.connect(to: listener)
        defer {
            connection.cancel()
            listener.cancel()
        }

        // Answering this is what makes the listener accept the connection.
        let early = try await self.send(connection, name: "early", request: "one")
        XCTAssertEqual(early, "early one")

        listener.setMessageHandler(name: "late") { (_: XPCConnection, request: String) -> String in
            "late \(request)"
        }
        let late = try await self.send(connection, name: "late", request: "two")
        XCTAssertEqual(late, "late two")
    }

    func testListenerHandlerReplacedAfterAcceptAnswersFromThenOn() async throws {
        let listener = try self.makeListener()
        listener.setMessageHandler(name: "version") { (_: XPCConnection, _: String) -> String in "first" }
        listener.activate()
        let connection = try self.connect(to: listener)
        defer {
            connection.cancel()
            listener.cancel()
        }

        let before = try await self.send(connection, name: "version", request: "")
        XCTAssertEqual(before, "first")

        listener.setMessageHandler(name: "version") { (_: XPCConnection, _: String) -> String in "second" }
        let after = try await self.send(connection, name: "version", request: "")
        XCTAssertEqual(after, "second")
    }

    func testConnectionsOwnHandlerAnswersBeforeTheListeners() async throws {
        let listener = try self.makeListener()
        listener.setMessageHandler(name: "greet") { (_: XPCConnection, _: String) -> String in "listener" }
        // Sets a handler on the accepted connection itself, which only that
        // connection answers with.
        listener.setMessageHandler(name: "personalize") { (connection: XPCConnection, _: String) -> String in
            connection.setMessageHandler(name: "greet") { (_: XPCConnection, _: String) -> String in "connection" }
            return "done"
        }
        listener.activate()
        let connection = try self.connect(to: listener)
        defer {
            connection.cancel()
            listener.cancel()
        }

        let before = try await self.send(connection, name: "greet", request: "")
        XCTAssertEqual(before, "listener")
        _ = try await self.send(connection, name: "personalize", request: "")
        let after = try await self.send(connection, name: "greet", request: "")
        XCTAssertEqual(after, "connection")
    }

    /// An instance of a service the bundle does not embed fails like any missing service.
    ///
    /// A test bundle embeds no XPC service, so this only proves the instance
    /// is set up without trapping. Starting real instances needs an app that
    /// embeds a `_MultipleInstances` service.
    func testServiceInstanceConnectionToAMissingServiceIsInvalid() async throws {
        let connection = try XPCConnection(
            type: .remoteServiceInstance(
                bundleID: "com.charlessoft.SwiftyXPC.Tests.MissingService",
                instance: UUID().uuid
            )
        )
        connection.errorHandler = { _, _ in }
        connection.activate()
        defer { connection.cancel() }

        do {
            _ = try await self.send(connection, name: "anything", request: "")
            XCTFail("A connection to a service the bundle does not embed answered")
        } catch let error as XPCError {
            guard case .connectionInvalid = error else {
                return XCTFail("Expected connectionInvalid, got \(error)")
            }
        }
    }
}
#endif
