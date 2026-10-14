#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing
import XPC

@testable import SwiftyXPC

/// Tests of what travels over a connection, run against an anonymous listener in this process.
///
/// Both ends live in the test process, so these need no launchd job and can run in parallel.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
struct MessageDeliveryTests {
    /// An error whose `encode(to:)` always fails, standing in for any error type that cannot be encoded.
    struct UnencodableError: Error, Codable {
        init() {}

        init(from decoder: any Decoder) throws {
            self.init()
        }

        func encode(to encoder: any Encoder) throws {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "This error refuses to be encoded.")
            )
        }
    }

    /// A listener in this process and a connection to it.
    final class Pair {
        let listener: SwiftyXPC.XPCListener
        let connection: XPCConnection
        let connectionErrors = Recorder<String>()

        init(configure: (SwiftyXPC.XPCListener) -> Void) throws {
            self.listener = try SwiftyXPC.XPCListener(type: .anonymous)
            configure(self.listener)
            self.listener.activate()

            self.connection = try XPCConnection(type: .remoteServiceFromEndpoint(self.listener.endpoint))

            let connectionErrors = self.connectionErrors
            self.connection.errorHandler = { _, error in
                connectionErrors.record(String(describing: error))
            }

            self.connection.activate()
        }

        deinit {
            self.connection.cancel()
            self.listener.cancel()
        }
    }

    /// Regression test: the receiver used to answer every one-way message with a message of its own.
    ///
    /// After the handler for a one-way message returned, the receiver tried to reply. A one-way message has
    /// no reply context, so `xpc_dictionary_create_reply` returned `NULL` and the receiver sent a brand-new
    /// message instead — one without a name — and the sender's error handler reported `missingMessageName`.
    @Test func `A one-way message sends nothing back to its sender`() async throws {
        let notes = Recorder<String>()

        let pair = try Pair { listener in
            listener.setMessageHandler(name: "note") { (_, note: String) in
                notes.record(note)
            }

            listener.setMessageHandler(name: "ping") { _ in
                "pong"
            }
        }

        try pair.connection.sendOnewayMessage(name: "note", message: "hello")
        #expect(try await notes.waitUntil(count: 1))

        // Anything the receiver sent back after handling the note has had time to arrive once a round trip
        // has completed after it, with a margin for the receiver's handler tasks to run in any order.
        let pong: String = try await pair.connection.sendMessage(name: "ping")
        #expect(pong == "pong")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(pair.connectionErrors.values.isEmpty)
    }

    /// Regression test: a message nobody handled used to leave its sender with a misleading error.
    ///
    /// The receiver never replied, so XPC told the sender `connectionInterrupted` — indistinguishable from the
    /// receiver crashing — when the real problem was a misspelled name or a receiver without that handler.
    @Test func `A message nobody handles is answered with unexpectedMessage`() async throws {
        let pair = try Pair { _ in }

        let error = await #expect(throws: XPCConnection.Error.self) {
            try await pair.connection.sendMessage(name: "no such message")
        }
        #expect(error?.isUnexpectedMessage == true)
    }

    /// Regression test: a message without a name used to go unanswered, for the same reason as an unknown name.
    @Test func `A message without a name is answered with missingMessageName`() async throws {
        let pair = try Pair { _ in }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(message, WireFormat.bodyKey, xpc_null_create())

        let reply = await sendRawMessage(message, to: pair.listener.endpoint)

        try #require(xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
        let encodedError = try #require(xpc_dictionary_get_value(reply, WireFormat.errorKey))
        let error = try XPCErrorRegistry.shared.decodeError(encodedError)
        #expect((error as? XPCConnection.Error)?.isMissingMessageName == true)
    }

    /// Regression test: an error that could not be encoded used to vanish.
    ///
    /// Encoding the handler's error threw inside the unstructured task that ran the handler, and nothing caught
    /// it: the sender received no reply and saw `connectionInterrupted`.
    @Test func `An error that cannot be encoded still reaches the sender`() async throws {
        let pair = try Pair { listener in
            listener.setMessageHandler(name: "fail") { _ in
                throw UnencodableError()
            }
        }

        let error = await #expect(throws: XPCErrorRegistry.BoxedError.self) {
            try await pair.connection.sendMessage(name: "fail")
        }
        #expect(error?.errorDomain == String(reflecting: UnencodableError.self))
    }
    /// Nobody waits for the outcome of a one-way message, so its handler's error is reported where it happened.
    @Test func `A one-way message's handler error is reported on the receiving side`() async throws {
        let receiverErrors = Recorder<String>()

        let pair = try Pair { listener in
            listener.setMessageHandler(name: "note") { (_, _: String) in
                throw UnencodableError()
            }

            listener.setMessageHandler(name: "ping") { _ in
                "pong"
            }

            listener.errorHandler = { _, error in
                receiverErrors.record(String(describing: error))
            }
        }

        try pair.connection.sendOnewayMessage(name: "note", message: "hello")
        #expect(try await receiverErrors.waitUntil(count: 1))

        let pong: String = try await pair.connection.sendMessage(name: "ping")
        #expect(pong == "pong")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(receiverErrors.values == [String(describing: UnencodableError())])
        #expect(pair.connectionErrors.values.isEmpty)
    }

    /// The details of an error that fails to encode are lost to the sender, so the receiver hears why.
    @Test func `An error that cannot be encoded is reported on the receiving side`() async throws {
        let receiverErrors = Recorder<String>()

        let pair = try Pair { listener in
            listener.setMessageHandler(name: "fail") { _ in
                throw UnencodableError()
            }

            listener.errorHandler = { _, error in
                receiverErrors.record(String(describing: type(of: error)))
            }
        }

        await #expect(throws: XPCErrorRegistry.BoxedError.self) {
            try await pair.connection.sendMessage(name: "fail")
        }

        #expect(try await receiverErrors.waitUntil(count: 1))
        #expect(receiverErrors.values == [String(describing: EncodingError.self)])
    }

    /// Regression test: `XPCEncoder(replyingTo:)` used to stop at a precondition, whatever it was asked to encode.
    @Test func `A reply encoded by XPCEncoder(replyingTo:) reaches its sender`() async throws {
        let listener = RawListener { message, peer in
            guard let reply = try? XPCEncoder(replyingTo: message).encode(CoderRoundTripTests.KeyedIdentifier(value: "reply")) else {
                return
            }

            xpc_connection_send_message(peer, reply)
        }

        let reply = await sendRawMessage(xpc_dictionary_create(nil, nil, 0), toEndpointObject: listener.endpoint)

        try #require(xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
        #expect(try XPCDecoder().decode(type: CoderRoundTripTests.FlexibleIdentifier.self, from: reply).value == "reply")
    }
}

extension XPCConnection.Error {
    /// Whether this is `.unexpectedMessage`.
    var isUnexpectedMessage: Bool {
        if case .unexpectedMessage = self {
            return true
        }

        return false
    }

    /// Whether this is `.missingMessageName`.
    var isMissingMessageName: Bool {
        if case .missingMessageName = self {
            return true
        }

        return false
    }
}
#endif
