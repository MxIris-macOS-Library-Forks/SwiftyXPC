#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing
import XPC

@testable import SwiftyXPC

/// Tests that SwiftyXPC 1.0 and 0.5 understand each other's messages.
///
/// Peers are often updated separately — a privileged helper outlives several versions of its app — so the wire format
/// that 0.5 produces and expects is a contract. These tests pin it down without a 0.5 build at hand.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
struct WireCompatibilityTests {
    /// `XPCError` as SwiftyXPC 0.5 declares it.
    ///
    /// Its synthesized `Codable` conformance is the format 0.5 peers use.
    enum LegacyXPCError: Error, Codable, Equatable {
        case connectionInterrupted
        case connectionInvalid
        case terminationImminent
        case invalidCodeSignatureRequirement
        case unknown(String)
    }

    private func reencode<Source: Encodable, Destination: Decodable>(
        _ value: Source,
        as destinationType: Destination.Type
    ) throws -> Destination {
        try XPCDecoder().decode(type: destinationType, from: XPCEncoder().encode(value))
    }

    @Test func `An invalid connection from a 0.5 peer arrives without a reason`() throws {
        let error = try self.reencode(LegacyXPCError.connectionInvalid, as: XPCError.self)

        #expect(error.isConnectionInvalid)
        #expect(error.invalidationReason == nil)
    }

    @Test(arguments: ["xpc_connection_cancel()", nil] as [String?])
    func `An invalid connection reaches a 0.5 peer as plain connectionInvalid`(reason: String?) throws {
        let legacyError = try self.reencode(XPCError.connectionInvalid(reason: reason), as: LegacyXPCError.self)

        #expect(legacyError == .connectionInvalid)
    }

    @Test func `Unchanged cases decode the same in both directions`() throws {
        let currentError = try self.reencode(LegacyXPCError.unknown("Peer Forbidden"), as: XPCError.self)
        #expect(currentError.unknownDescription == "Peer Forbidden")

        let legacyError = try self.reencode(XPCError.unknown("Peer Forbidden"), as: LegacyXPCError.self)
        #expect(legacyError == .unknown("Peer Forbidden"))
        #expect(try self.reencode(XPCError.connectionInterrupted, as: LegacyXPCError.self) == .connectionInterrupted)
    }

    /// The registry finds `XPCError` by this domain on both sides, so it must not change.
    @Test func `XPCError keeps its error domain`() {
        #expect(String(reflecting: XPCError.self) == "SwiftyXPC.XPCError")
        #expect(String(reflecting: XPCConnection.Error.self) == "SwiftyXPC.XPCConnection.Error")
    }
    /// Opens a connection from this library to `listener`, a stand-in for a peer built with something else.
    private func connect(to listener: RawListener) throws -> XPCConnection {
        let endpoint = try SwiftyXPC.XPCEndpoint(xpcObject: listener.endpoint)
        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
        connection.activate()
        return connection
    }

    /// Sends `pong` as `reply`, the way any version of SwiftyXPC would answer a request.
    ///
    /// A message's reply context moves into the first reply created for it; a second `xpc_dictionary_create_reply`
    /// returns `NULL`, and dropping the first one unsent tells the sender the connection was interrupted.
    private static func answer(with reply: xpc_object_t, over peer: xpc_connection_t) {
        xpc_dictionary_set_value(reply, WireFormat.bodyKey, xpc_string_create("pong"))
        xpc_connection_send_message(peer, reply)
    }

    @Test func `Requests and one-way messages carry protocol version 1`() async throws {
        let messages = Recorder<UncheckedXPCObject>()
        let listener = RawListener { message, peer in
            messages.record(UncheckedXPCObject(object: message))

            if let reply = xpc_dictionary_create_reply(message) {
                Self.answer(with: reply, over: peer)
            }
        }

        let connection = try self.connect(to: listener)
        defer { connection.cancel() }

        try connection.sendOnewayMessage(name: "note", message: "hello")
        let pong: String = try await connection.sendMessage(name: "ping")
        #expect(pong == "pong")

        #expect(try await messages.waitUntil(count: 2))
        #expect(messages.values.map { xpc_dictionary_get_int64($0.object, WireFormat.protocolVersionKey) } == [1, 1])
    }

    @Test func `Replies carry protocol version 1`() async throws {
        let listener = try SwiftyXPC.XPCListener(type: .anonymous)
        listener.setMessageHandler(name: "ping") { _ in
            "pong"
        }
        listener.activate()
        defer { listener.cancel() }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, WireFormat.nameKey, "ping")
        xpc_dictionary_set_value(message, WireFormat.bodyKey, xpc_null_create())

        let reply = await sendRawMessage(message, to: listener.endpoint)

        #expect(xpc_dictionary_get_int64(reply, WireFormat.protocolVersionKey) == 1)
    }

    /// A 0.5 sender puts no protocol version on its messages.
    @Test func `A request without a protocol version is answered`() async throws {
        let listener = try SwiftyXPC.XPCListener(type: .anonymous)
        listener.setMessageHandler(name: "capitalize") { (_, text: String) in
            text.uppercased()
        }
        listener.activate()
        defer { listener.cancel() }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, WireFormat.nameKey, "capitalize")
        xpc_dictionary_set_value(message, WireFormat.bodyKey, xpc_string_create("from 0.5"))

        let reply = await sendRawMessage(message, to: listener.endpoint)

        try #require(xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
        let body = try #require(xpc_dictionary_get_value(reply, WireFormat.bodyKey))
        #expect(try XPCDecoder().decode(type: String.self, from: body) == "FROM 0.5")
    }

    /// A 0.5 receiver answers every one-way message with a nameless message of its own; it carries nothing to act on.
    @Test func `The stray answer of a 0.5 receiver to a one-way message is ignored`() async throws {
        let listener = RawListener { message, peer in
            if let reply = xpc_dictionary_create_reply(message) {
                Self.answer(with: reply, over: peer)
            } else {
                let strayAnswer = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_value(strayAnswer, WireFormat.bodyKey, xpc_null_create())
                xpc_connection_send_message(peer, strayAnswer)
            }
        }

        let errors = Recorder<String>()
        let connection = try self.connect(to: listener)
        connection.errorHandler = { _, error in
            errors.record(String(describing: error))
        }
        defer { connection.cancel() }

        try connection.sendOnewayMessage(name: "note", message: "hello")

        // The stray answer travels ahead of this reply on the same connection, and both are handled on its queue.
        let pong: String = try await connection.sendMessage(name: "ping")
        #expect(pong == "pong")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(errors.values.isEmpty)
    }

    /// A 0.5 receiver also sends the error of a one-way message's handler back; that one is worth reporting.
    @Test func `An error that a 0.5 receiver sends back for a one-way message is reported`() async throws {
        // Only one-way messages arrive here, so there is no reply context to take.
        let listener = RawListener { _, peer in
            guard let encodedError = try? XPCErrorRegistry.shared.encodeError(XPCError.unknown("handler failed")) else {
                return
            }

            let errorMessage = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(errorMessage, WireFormat.errorKey, encodedError)
            xpc_connection_send_message(peer, errorMessage)
        }

        let errors = Recorder<String>()
        let connection = try self.connect(to: listener)
        connection.errorHandler = { _, error in
            errors.record((error as? XPCError)?.unknownDescription ?? String(describing: error))
        }
        defer { connection.cancel() }

        try connection.sendOnewayMessage(name: "note", message: "hello")

        #expect(try await errors.waitUntil(count: 1))
        #expect(errors.values == ["handler failed"])
    }
}
#endif
