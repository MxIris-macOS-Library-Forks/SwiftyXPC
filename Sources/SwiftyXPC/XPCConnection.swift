#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
import System
import XPC

// `xpc_connection_get_audit_token` is a stable but unpublished SPI exported from libSystem
// since macOS 10.8. Re-declared here so callers can validate peer connections against a
// `SecRequirement` using the audit token, which avoids the TOCTOU window inherent to
// PID-based lookups via `SecCodeCopyGuestWithAttributes(kSecGuestAttributePid:)`.
@_silgen_name("xpc_connection_get_audit_token")
private func swiftyxpc_xpc_connection_get_audit_token(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

/// A bidirectional communication channel between two processes.
///
/// Use this class’s `init(type:codeSigningRequirement:)` initializer to connect to an `XPCListener` instance in another process.
///
/// Use the `sendMessage` family of functions to send messages to the remote process, and `setMessageHandler(name:handler:)` to receive them.
///
/// The connection must receive `.activate()` before it can send or receive any messages.
public class XPCConnection: @unchecked Sendable {
    /// Errors specific to `XPCConnection`.
    public enum Error: Swift.Error, Codable {
        /// An XPC message was missing its name.
        case missingMessageName
        /// An XPC message was missing its request and/or response body.
        case missingMessageBody
        /// Received an unhandled XPC message.
        case unexpectedMessage
        /// A message contained data of the wrong type.
        case typeMismatch(expected: XPCType, actual: XPCType)
        /// A peer failed the code signing check that SwiftyXPC made itself on macOS versions prior to 12.0.
        ///
        /// SwiftyXPC no longer runs on those versions, and leaves peer checks to XPC, so this error is never produced.
        @available(*, deprecated, message: "SwiftyXPC no longer produces this error; XPC checks peers itself on macOS 12 and later.")
        case callerFailedCredentialCheck(OSStatus)
    }

    private struct MessageKeys {
        static let name = "com.charlessoft.SwiftyXPC.XPCEventHandler.Name"
        static let body = "com.charlessoft.SwiftyXPC.XPCEventHandler.Body"
        static let error = "com.charlessoft.SwiftyXPC.XPCEventHandler.Error"
    }

    /// Represents the various types of connection that can be created.
    public enum ConnectionType {
        /// Connect to an embedded XPC service inside the current application’s bundle. Pass the XPC service’s bundle ID as the `bundleID` parameter.
        case remoteService(bundleID: String)
        /// Create a connection from a passed-in endpoint, which typically will come embedded in an XPC message.
        case remoteServiceFromEndpoint(XPCEndpoint)
        /// Connect to a remote Mach service by its service name.
        case remoteMachService(serviceName: String, isPrivilegedHelperTool: Bool)
    }

    /// A handler that will be called if a communication error occurs.
    public typealias ErrorHandler = (XPCConnection, Swift.Error) -> Void

    internal class MessageHandler {
        typealias RawHandler = ((XPCConnection, xpc_object_t) async throws -> xpc_object_t)
        let closure: RawHandler
        let requestType: Codable.Type
        let responseType: Codable.Type

        init<Request: Codable, Response: Codable>(closure: @escaping (XPCConnection, Request) async throws -> Response) {
            self.requestType = Request.self
            self.responseType = Response.self

            self.closure = { connection, event in
                guard let body = xpc_dictionary_get_value(event, MessageKeys.body) else {
                    throw Error.missingMessageBody
                }

                let request = try XPCDecoder().decode(type: Request.self, from: body)
                let response = try await closure(connection, request)

                return try XPCEncoder().encode(response)
            }
        }
    }

    private let connection: xpc_connection_t

    internal static func makeAnonymousListenerConnection(codeSigningRequirement: String?) throws -> XPCConnection {
        try .init(connection: xpc_connection_create(nil, nil), codeSigningRequirement: codeSigningRequirement)
    }

    /// Initialize a new `XPCConnection`.
    ///
    /// - Parameters:
    ///   - type: The type of connection to create. See the documentation for `ConnectionType` for possible values.
    ///   - requirement: An optional code signing requirement. If specified, the connection will reject all messages from processes that do not meet the specified requirement.
    ///
    /// - Throws: Any errors that come up in the process of initializing the connection.
    public convenience init(type: ConnectionType, codeSigningRequirement requirement: String? = nil) throws {
        switch type {
        case .remoteService(let bundleID):
            try self.init(connection: xpc_connection_create(bundleID, nil), codeSigningRequirement: requirement)
        case .remoteServiceFromEndpoint(let endpoint):
            try self.init(connection: endpoint.makeConnection(), codeSigningRequirement: requirement)
        case .remoteMachService(serviceName: let name, isPrivilegedHelperTool: let isPrivileged):
            let flags: Int32 = isPrivileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0
            try self.init(machServiceName: name, flags: flags, codeSigningRequirement: requirement)
        }
    }

    internal convenience init(machServiceName: String, flags: Int32, codeSigningRequirement: String? = nil) throws {
        let connection = xpc_connection_create_mach_service(machServiceName, nil, UInt64(flags))

        do {
            try self.init(connection: connection, codeSigningRequirement: codeSigningRequirement)
        } catch {
            // To avoid xpc_api_misuse errors from the connection being released without having been fully initialized
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            xpc_connection_cancel(connection)
            throw error
        }
    }

    internal init(connection: xpc_connection_t, codeSigningRequirement: String?) throws {
        self.connection = connection

        if let requirement = codeSigningRequirement {
            guard xpc_connection_set_peer_code_signing_requirement(self.connection, requirement) == 0 else {
                throw XPCError.invalidCodeSignatureRequirement
            }
        }

        xpc_connection_set_event_handler(self.connection, self.handleEvent)
    }

    internal var messageHandlers: [String: MessageHandler] = [:]

    /// A handler that will be called if a communication error occurs.
    public var errorHandler: ErrorHandler? = nil

    internal var customEventHandler: xpc_handler_t? = nil

    internal func getMessageHandler(forName name: String) -> MessageHandler.RawHandler? {
        self.messageHandlers[name]?.closure
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments or returning any value.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:)`.
    ///   - handler: Pass a function that processes the message, optionally throwing an error.
    public func setMessageHandler(name: String, handler: @escaping (XPCConnection) async throws -> Void) {
        self.setMessageHandler(name: name) { (connection: XPCConnection, _: XPCNull) async throws -> XPCNull in
            try await handler(connection)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, taking an argument but not returning any value.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:request:)`.
    ///   - handler: Pass a function that processes the message, optionall throwing an error. The request value must
    ///     conform to the `Codable` protocol, and will automatically be type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Codable>(
        name: String,
        handler: @escaping (XPCConnection, Request) async throws -> Void
    ) {
        self.setMessageHandler(name: name) { (connection: XPCConnection, request: Request) async throws -> XPCNull in
            try await handler(connection, request)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments but returning a value.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:)`.
    ///   - handler: Pass a function that processes the message and either returns a value or throws an error. The return value must
    ///     conform to the `Codable` protocol.
    public func setMessageHandler<Response: Codable>(
        name: String,
        handler: @escaping (XPCConnection) async throws -> Response
    ) {
        self.setMessageHandler(name: name) { (connection: XPCConnection, _: XPCNull) in
            try await handler(connection)
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, taking an argument and returning a value.
    ///
    /// Example usage:
    ///
    ///     connection.setMessageHandler(
    ///         name: "com.example.SayHello",
    ///         handler: self.sayHello
    ///     )
    ///
    ///     // ... later in the same class ...
    ///
    ///     func sayHello(
    ///         connection: XPCConnection,
    ///         message: String
    ///     ) async throws -> String {
    ///         self.logger.notice("Caller sent message: \(message)")
    ///
    ///         if message == "Hello, World!" {
    ///             return "Hello back!"
    ///         } else {
    ///             throw RudeCallerError(message: "You didn't say hello!")
    ///         }
    ///     }
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:request:)`.
    ///   - handler: Pass a function that processes the message and either returns a value or throws an error. Both the request and return values must conform to the `Codable` protocol. The types are automatically type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Codable, Response: Codable>(
        name: String,
        handler: @escaping (XPCConnection, Request) async throws -> Response
    ) {
        self.messageHandlers[name] = MessageHandler(closure: handler)
    }

    #if os(macOS)
    /// The audit session identifier associated with the remote process.
    public var auditSessionIdentifier: au_asid_t {
        xpc_connection_get_asid(self.connection)
    }
    #endif

    /// The effective group identifier associated with the remote process.
    public var effectiveGroupIdentifier: gid_t {
        xpc_connection_get_egid(self.connection)
    }

    /// The effective user identifier associated with the remote process.
    public var effectiveUserIdentifier: uid_t {
        xpc_connection_get_euid(self.connection)
    }

    #if os(macOS)
    /// The process ID of the remote process.
    public var processIdentifier: pid_t {
        xpc_connection_get_pid(self.connection)
    }
    #endif

    /// The audit token of the remote process.
    ///
    /// The audit token uniquely identifies a peer process and is suitable for use with
    /// `SecCodeCopyGuestWithAttributes` (using `kSecGuestAttributeAudit`) to obtain a
    /// `SecCode` reference that can be validated against a `SecRequirement`.
    ///
    /// Prefer this over `processIdentifier` when performing code-signing checks: a PID
    /// can be reused after the original peer exits, leaving a TOCTOU window in which a
    /// different process could be inspected. The audit token does not have this issue.
    public var auditToken: audit_token_t {
        var token = audit_token_t(val: (0, 0, 0, 0, 0, 0, 0, 0))
        withUnsafeMutablePointer(to: &token) { tokenPointer in
            swiftyxpc_xpc_connection_get_audit_token(self.connection, tokenPointer)
        }
        return token
    }

    /// Activate the connection.
    ///
    /// Connections start in an inactive state, so you must call `activate()` on a connection before it will send or receive any messages.
    public func activate() {
        xpc_connection_activate(self.connection)
    }

    /// Suspends the connection so that the event handler block doesn't fire and the connection doesn't attempt to send any messages it has in its queue.
    ///
    /// All calls to `suspend()` must be balanced with calls to `resume()` before releasing the last reference to the connection.
    ///
    /// Suspension is asynchronous and non-preemptive, and therefore this method will not interrupt the execution of an already-running event handler block.
    /// If the event handler is executing at the time of this call, it will finish, and then the connection will be suspended before the next scheduled invocation of
    /// the event handler. The XPC runtime guarantees this non-preemptiveness even for concurrent target queues.
    public func suspend() {
        xpc_connection_suspend(self.connection)
    }

    /// Resumes a suspended connection.
    ///
    /// In order for a connection to become live, every call to `suspend()` must be balanced with a call to `resume()`.
    /// Calling `resume()` more times than `suspend()` has been called is considered an error.
    public func resume() {
        xpc_connection_resume(self.connection)
    }

    /// Cancels the connection and ensures that its event handler doesn't fire again.
    ///
    /// After this call, any messages that have not yet been sent will be discarded, and the connection will be unwound.
    /// If there are messages that are awaiting replies, they will receive the `XPCError.connectionInvalid` error.
    public func cancel() {
        xpc_connection_cancel(self.connection)
    }

    internal func makeEndpoint() -> XPCEndpoint {
        XPCEndpoint(connection: self.connection)
    }

    /// Send a message to an `XPCConnection` in another process without any parameters.
    ///
    /// - Parameter name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///
    /// - Throws: Throws an error if the receiving connection throws an error in its handler, or if a communication error occurs.
    public func sendMessage(name: String) async throws {
        try await self.sendMessage(name: name, request: XPCNull.shared)
    }

    /// Send a message to an `XPCConnection` in another process that takes a parameter.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///   - request: A parameter that will be passed to the receiving connection’s handler function. The type of the request must match the type specified by the receiving connection.
    ///
    /// - Throws: Throws an error the `request` parameter does not match the type specified by the receiving connection’s handler function,
    ///   if the receiving connection throws an error in its handler, or if a communication error occurs.
    public func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        _ = try await self.sendMessage(name: name, request: request) as XPCNull
    }

    /// Send a message to an `XPCConnection` in another process that does not take a parameter, and receives a response.
    ///
    /// - Parameter name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///
    /// - Returns: The value returned by the receiving connection's helper function.
    ///
    /// - Throws: Throws an error if the receiving connection throws an error in its handler, or if a communication error occurs.
    public func sendMessage<Response: Codable & Sendable>(name: String) async throws -> Response {
        try await self.sendMessage(name: name, request: XPCNull.shared)
    }

    /// Send a message to an `XPCConnection` in another process that takes a parameter.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///   - request: A parameter that will be passed to the receiving connection’s handler function. The type of the request must match the type specified by the receiving connection.
    ///
    /// - Returns: The value returned by the receiving connection's helper function.
    ///
    /// - Throws: Throws an error the `request` parameter does not match the type specified by the receiving connection’s handler function,
    ///   if the receiving connection throws an error in its handler, or if a communication error occurs.
    public func sendMessage<Response: Codable & Sendable>(name: String, request: some Codable) async throws -> Response {
        let body = try XPCEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let message = xpc_dictionary_create(nil, nil, 0)

            xpc_dictionary_set_string(message, MessageKeys.name, name)
            xpc_dictionary_set_value(message, MessageKeys.body, body)

            xpc_connection_send_message_with_reply(self.connection, message, nil) { event in
                do {
                    switch event.type {
                    case .dictionary: break
                    case .error: throw XPCError(error: event)
                    default: throw Error.typeMismatch(expected: .dictionary, actual: event.type)
                    }

                    if let error = xpc_dictionary_get_value(event, MessageKeys.error) {
                        throw try XPCErrorRegistry.shared.decodeError(error)
                    }

                    guard let body = xpc_dictionary_get_value(event, MessageKeys.body) else {
                        throw Error.missingMessageBody
                    }

                    let response: Response = if Response.self == XPCNull.self {
                        XPCNull() as! Response
                    } else {
                        try XPCDecoder().decode(type: Response.self, from: body)
                    }

                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Send a message, and do not wait for a reply.
    ///
    /// - Parameters:
    ///   - message: A parameter that will be passed to the receiving connection’s handler function. This must match the type specified in the receiving connection’s handler function.
    ///   - name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///
    /// - Throws: Any communication errors that occur in the process of sending the message.
    public func sendOnewayMessage<Message: Codable>(name: String? = nil, message: Message) throws {
        let xpcMessage = xpc_dictionary_create(nil, nil, 0)

        if let name = name {
            xpc_dictionary_set_string(xpcMessage, MessageKeys.name, name)
        }

        xpc_dictionary_set_value(xpcMessage, MessageKeys.body, try XPCEncoder().encode(message))

        xpc_connection_send_message(self.connection, xpcMessage)
    }

    /// Answers `request` with `result`, if the sender of `request` is waiting for a reply.
    ///
    /// - Returns: Whether the sender was waiting for a reply. A one-way message has no reply context, and gets none.
    @discardableResult
    private func reply(to request: xpc_object_t, with result: Result<xpc_object_t, Swift.Error>) -> Bool {
        guard let reply = xpc_dictionary_create_reply(request) else {
            return false
        }

        switch result {
        case .success(let body):
            xpc_dictionary_set_value(reply, MessageKeys.body, body)
        case .failure(let error):
            xpc_dictionary_set_value(reply, MessageKeys.error, self.encodeForReply(error))
        }

        xpc_connection_send_message(self.connection, reply)
        return true
    }

    /// Encodes `error` for a reply, falling back to its domain and code if the error itself fails to encode.
    private func encodeForReply(_ error: Swift.Error) -> xpc_object_t {
        do {
            return try XPCErrorRegistry.shared.encodeError(error)
        } catch let encodingError {
            // The sender still learns which error it was; this side learns why the details were lost.
            self.errorHandler?(self, encodingError)

            return XPCErrorRegistry.shared.encodeErrorWithoutPayload(error)
        }
    }

    /// Issues a barrier against the connection's message-send activity.
    ///
    /// - Parameter barrier: The barrier block to issue.
    ///     This barrier prevents concurrent message-send activity on the connection.
    ///     No messages will be sent while the barrier block is executing.
    ///
    /// XPC guarantees that, even if the connection's target queue is a concurrent queue, there are no other messages being sent concurrently
    /// while the barrier block is executing.
    /// XPC does not guarantee that the receipt of messages (either through the connection's event handler or through reply handlers) will be
    /// suspended while the barrier is executing.
    ///
    /// A barrier is issued relative to the message-send queue. So, if you call `sendMessage(name:request:)` five times and then call `sendBarrier(_:)`,
    /// the barrier will be invoked after the fifth message has been sent and its memory disposed of.
    /// You may safely cancel a connection from within a barrier block.
    ///
    /// If a barrier is issued after sending a message which expects a reply, the behavior is the same as described above.
    /// The receipt of a reply message will not influence when the barrier runs.
    ///
    /// A barrier block can be useful for throttling resource consumption on the connected side of a connection.
    /// For example, if your connection sends many large messages, you can use a barrier to limit the number of messages that are inflight at any given time.
    /// This can be particularly useful for messages that contain kernel resources (like file descriptors) which have a systemwide limit.
    ///
    /// If a barrier is issued on a canceled connection, it will be invoked immediately.
    /// If a connection has been canceled and still has outstanding barriers, those barriers will be invoked as part of the connection's unwinding process.
    ///
    /// It is important to note that a barrier block's execution order is not guaranteed with respect to other blocks that have been scheduled on the
    /// target queue of the connection. Or said differently, `sendBarrier(_:)` is not equivalent to `DispatchQueue.async`.
    public func sendBarrier(_ barrier: @escaping () -> Void) {
        xpc_connection_send_barrier(self.connection, barrier)
    }

    private func handleEvent(_ event: xpc_object_t) {
        if let customEventHandler = self.customEventHandler {
            customEventHandler(event)
            return
        }

        do {
            switch event.type {
            case .dictionary:
                if let error = xpc_dictionary_get_value(event, MessageKeys.error) {
                    throw try XPCErrorRegistry.shared.decodeError(error)
                }

                self.respond(to: event)
            case .error:
                throw XPCError(error: event)
            default:
                throw Error.typeMismatch(expected: .dictionary, actual: event.type)
            }
        } catch {
            self.errorHandler?(self, error)
            return
        }
    }
    private func respond(to event: xpc_object_t) {
        struct SendableWrapper: @unchecked Sendable {
            let event: xpc_object_t
        }

        let wrapper = SendableWrapper(event: event)

        Task {
            let event = wrapper.event

            let messageHandler: MessageHandler.RawHandler

            do {
                guard let name = xpc_dictionary_get_value(event, MessageKeys.name).flatMap({ String($0) }) else {
                    throw Error.missingMessageName
                }

                guard let _messageHandler = self.getMessageHandler(forName: name) else {
                    throw Error.unexpectedMessage
                }

                messageHandler = _messageHandler
            } catch {
                // This side learns that it was sent a message it cannot route. A sender that is waiting for a reply
                // learns why it will not get the one it wanted, instead of seeing the connection as interrupted.
                self.errorHandler?(self, error)
                self.reply(to: event, with: .failure(error))
                return
            }

            let result: Result<xpc_object_t, Swift.Error>

            do {
                result = .success(try await messageHandler(self, event))
            } catch {
                result = .failure(error)
            }

            if !self.reply(to: event, with: result), case .failure(let error) = result {
                // Nobody is waiting for the outcome of a one-way message, so its handler's error is reported here.
                self.errorHandler?(self, error)
            }
        }
    }

    @available(*, deprecated, message: "Use sendOnewayMessage(name:message:) instead")
    public func sendOnewayMessage<Message: Codable>(message: Message, name: String?) throws {
        try self.sendOnewayMessage(name: name, message: message)
    }
}
#endif
