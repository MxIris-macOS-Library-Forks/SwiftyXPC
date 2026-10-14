#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import XPC

@testable import SwiftyXPC

/// Collects values from any thread, such as the ones XPC calls message and error handlers on.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    /// Everything recorded so far, in the order it was recorded.
    var values: [Element] {
        self.lock.withLock { self.storage }
    }

    func record(_ value: Element) {
        self.lock.withLock { self.storage.append(value) }
    }

    /// Waits until at least `count` values have been recorded.
    ///
    /// - Returns: `false` if `timeout` elapsed first.
    func waitUntil(count: Int, timeout: TimeInterval = 10) async throws -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while self.values.count < count {
            if Date.now >= deadline {
                return false
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        return true
    }
}

extension XPCError {
    /// The description carried by `.unknown`, or `nil` for every other case.
    var unknownDescription: String? {
        if case .unknown(let description) = self {
            return description
        }

        return nil
    }

    /// Whether this is `.invalidCodeSignatureRequirement`.
    var isInvalidCodeSignatureRequirement: Bool {
        if case .invalidCodeSignatureRequirement = self {
            return true
        }

        return false
    }

    /// Whether this is `.invalidPeerRequirement`.
    var isInvalidPeerRequirement: Bool {
        if case .invalidPeerRequirement = self {
            return true
        }

        return false
    }

    /// The reason carried by `.connectionInvalid`; `nil` for every other case or when XPC gave no reason.
    var invalidationReason: String? {
        if case .connectionInvalid(let reason) = self {
            return reason
        }

        return nil
    }

    /// Whether this is `.connectionInvalid`.
    var isConnectionInvalid: Bool {
        if case .connectionInvalid = self {
            return true
        }

        return false
    }
}
/// The dictionary keys SwiftyXPC puts on the wire, spelled out independently of the library's own constants.
///
/// The keys are part of the wire format that peers built from other versions of SwiftyXPC depend on.
enum WireFormat {
    static let nameKey = "com.charlessoft.SwiftyXPC.XPCEventHandler.Name"
    static let bodyKey = "com.charlessoft.SwiftyXPC.XPCEventHandler.Body"
    static let errorKey = "com.charlessoft.SwiftyXPC.XPCEventHandler.Error"
    static let protocolVersionKey = "com.charlessoft.SwiftyXPC.XPCEventHandler.ProtocolVersion"
}

/// An XPC object that may cross into another task; XPC objects are safe to share between threads.
struct UncheckedXPCObject: @unchecked Sendable {
    let object: xpc_object_t
}

/// Sends `message` to the listener behind `endpoint` over a raw XPC connection and waits for the reply.
///
/// This bypasses `XPCConnection` entirely, so it can send messages the library itself would never produce.
func sendRawMessage(_ message: xpc_object_t, to endpoint: SwiftyXPC.XPCEndpoint) async -> xpc_object_t {
    await sendRawMessage(message, toEndpointObject: endpoint.endpoint)
}

/// Sends `message` to the listener behind a raw XPC endpoint object and waits for the reply.
func sendRawMessage(_ message: xpc_object_t, toEndpointObject endpoint: xpc_endpoint_t) async -> xpc_object_t {
    let connection = xpc_connection_create_from_endpoint(endpoint)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_activate(connection)
    defer { xpc_connection_cancel(connection) }

    let reply = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedXPCObject, Never>) in
        xpc_connection_send_message_with_reply(connection, message, nil) { reply in
            continuation.resume(returning: UncheckedXPCObject(object: reply))
        }
    }

    return reply.object
}
/// An anonymous listener built directly on the XPC C API, standing in for a peer that does not use this library.
final class RawListener: Sendable {
    private let listener: UncheckedXPCObject

    /// The endpoint that connects to this listener.
    var endpoint: xpc_endpoint_t {
        xpc_endpoint_create(self.listener.object)
    }

    /// Creates a listener that hands every dictionary it receives to `handleMessage`, with the connection it came on.
    init(handleMessage: @escaping @Sendable (_ message: xpc_object_t, _ peer: xpc_connection_t) -> Void) {
        let listener = xpc_connection_create(nil, nil)

        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
                return
            }

            let uncheckedPeer = UncheckedXPCObject(object: peer)

            xpc_connection_set_event_handler(peer) { message in
                if xpc_get_type(message) == XPC_TYPE_DICTIONARY {
                    handleMessage(message, uncheckedPeer.object)
                }
            }

            xpc_connection_activate(peer)
        }

        xpc_connection_activate(listener)
        self.listener = UncheckedXPCObject(object: listener)
    }

    deinit {
        xpc_connection_cancel(self.listener.object)
    }
}
#endif
