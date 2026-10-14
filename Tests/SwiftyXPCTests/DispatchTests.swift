#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
import Dispatch
import Foundation
import Testing

@testable import SwiftyXPC

/// Tests of how a connection runs the handlers for the messages that arrive on it.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
struct DispatchTests {
    /// Lets one handler wait, at a suspension point, until another handler has started.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if self.isOpen {
                return
            }

            await withCheckedContinuation { self.waiters.append($0) }
        }

        func open() {
            self.isOpen = true
            self.waiters.forEach { $0.resume() }
            self.waiters.removeAll()
        }
    }

    /// Opens a connection to an anonymous listener in this process whose accepted connections use `dispatchStrategy`.
    private func makeListener(
        dispatchStrategy: MessageDispatcher.Strategy = .automatic,
        configure: (SwiftyXPC.XPCListener) -> Void
    ) throws -> (listener: SwiftyXPC.XPCListener, connection: XPCConnection) {
        let listener = try SwiftyXPC.XPCListener(
            type: .anonymous,
            requirement: nil,
            peerDispatchStrategy: dispatchStrategy
        )
        configure(listener)
        listener.activate()

        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(listener.endpoint))
        connection.activate()

        return (listener, connection)
    }

    /// Handlers start in arrival order, even when consecutive messages arrive at different qualities of service, and
    /// a handler that suspends lets the next one start.
    ///
    /// The handler for message 0 waits for a gate that only the handler for message 1 opens. If handlers ran one at a
    /// time to completion, message 0 would wait forever and the test would time out. The test runs once for each
    /// dispatch strategy, so a new system also takes the paths that macOS 12 through 25 take.
    @Test(arguments: MessageDispatcher.Strategy.allCases)
    func `Handlers start in arrival order and interleave where they suspend`(
        dispatchStrategy: MessageDispatcher.Strategy
    ) async throws {
        let messageCount = 50
        let starts = Recorder<Int>()
        let finishes = Recorder<Int>()
        let gate = Gate()

        let (listener, connection) = try self.makeListener(dispatchStrategy: dispatchStrategy) { listener in
            listener.setMessageHandler(name: "step") { (_, index: Int) in
                starts.record(index)

                if index == 0 {
                    await gate.wait()
                } else if index == 1 {
                    await gate.open()
                }

                finishes.record(index)
            }
        }
        defer {
            connection.cancel()
            listener.cancel()
        }

        for index in 0..<messageCount {
            let qualityOfService: DispatchQoS.QoSClass = index.isMultiple(of: 2) ? .background : .userInteractive

            try DispatchQueue.global(qos: qualityOfService).sync {
                try connection.sendOnewayMessage(name: "step", message: index)
            }
        }

        #expect(try await finishes.waitUntil(count: messageCount))
        #expect(starts.values == Array(0..<messageCount))
    }

    @Test func `A handler learns who sent its message`() async throws {
        let contexts = Recorder<XPCMessageContext>()

        let (listener, connection) = try self.makeListener { listener in
            listener.setMessageHandler(name: "identify") { context in
                contexts.record(context)
            }
        }
        defer {
            connection.cancel()
            listener.cancel()
        }

        try await connection.sendMessage(name: "identify")
        try connection.sendOnewayMessage(name: "identify", message: XPCNull.shared)
        #expect(try await contexts.waitUntil(count: 2))

        let contextsByReplyExpectation = Dictionary(grouping: contexts.values, by: \.expectsReply)
        let request = try #require(contextsByReplyExpectation[true]?.first)
        let oneWayMessage = try #require(contextsByReplyExpectation[false]?.first)

        #expect(request.messageName == "identify")
        #expect(request.processIdentifier == getpid())
        #expect(request.effectiveUserIdentifier == geteuid())
        #expect(request.effectiveGroupIdentifier == getegid())
        #expect(oneWayMessage.processIdentifier == getpid())
    }

    @Test func `A handler set on a listener reaches connections it accepted earlier`() async throws {
        let (listener, connection) = try self.makeListener { listener in
            listener.setMessageHandler(name: "first") { _ in
                "first"
            }
        }
        defer {
            connection.cancel()
            listener.cancel()
        }

        let first: String = try await connection.sendMessage(name: "first")
        #expect(first == "first")

        listener.setMessageHandler(name: "second") { _ in
            "second"
        }

        let second: String = try await connection.sendMessage(name: "second")
        #expect(second == "second")
    }

    @Test func `A connection's own handler takes precedence over its listener's`() async throws {
        let echoConnections = Recorder<XPCConnection>()

        let (listener, connection) = try self.makeListener { listener in
            listener.setMessageHandler(name: "register") { context in
                echoConnections.record(context.connection)
            }

            listener.setMessageHandler(name: "greet") { _ in
                "from the listener"
            }
        }
        defer {
            connection.cancel()
            listener.cancel()
        }

        try await connection.sendMessage(name: "register")
        let acceptedConnection = try #require(echoConnections.values.first)

        acceptedConnection.setMessageHandler(name: "greet") { _ in
            "from the connection"
        }

        let greeting: String = try await connection.sendMessage(name: "greet")
        #expect(greeting == "from the connection")
    }

    /// Regression test: a connection whose code signing requirement does not parse must not crash on its way out.
    ///
    /// XPC treats releasing a connection that was never activated as API misuse.
    @Test func `An unparsable requirement on an endpoint connection throws`() throws {
        let listener = try SwiftyXPC.XPCListener(type: .anonymous)
        listener.activate()
        defer { listener.cancel() }

        let error = #expect(throws: XPCError.self) {
            _ = try XPCConnection(type: .remoteServiceFromEndpoint(listener.endpoint), requirement: .codeSigning(""))
        }
        #expect(error?.isInvalidCodeSignatureRequirement == true)
    }
}
#endif
