#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
import System
import XPC

/// A bidirectional communication channel between two processes.
///
/// Use this class’s `init(type:requirement:)` initializer to connect to an `XPCListener` instance in another process.
///
/// Use the `sendMessage` family of functions to send messages to the remote process, and `setMessageHandler(name:handler:)` to receive them.
///
/// The connection must receive `.activate()` before it can send or receive any messages.
///
/// ## Concurrency
///
/// Each connection has a serial executor of its own. The handlers for the messages that arrive on a connection start
/// on that executor in the order the messages arrive, and run there until they suspend: while one handler awaits,
/// the handler for the next message can start, the way it can with `NSXPCConnection`. A handler that must not overlap
/// with others should not suspend, or should coordinate through an actor of its own.
///
/// Handlers and the error handler must be `@Sendable`, because XPC calls them on its own threads. A request reaches
/// its handler as a `sending` value, so its type does not have to be `Sendable`. Neither does the response, which is
/// encoded on the executor the handler returns to — unless the handler is isolated elsewhere, for instance to the
/// main actor, in which case the compiler requires a `Sendable` response where the handler is passed in.
public class XPCConnection: @unchecked Sendable {
    // Unchecked because of `connection`, an XPC object whose thread safety libxpc guarantees. Every other stored
    // property is either immutable or guarded by a lock.

    /// Errors specific to `XPCConnection`.
    public enum Error: Swift.Error, Codable, Sendable {
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

    private enum MessageKeys {
        static let name = "com.charlessoft.SwiftyXPC.XPCEventHandler.Name"
        static let body = "com.charlessoft.SwiftyXPC.XPCEventHandler.Body"
        static let error = "com.charlessoft.SwiftyXPC.XPCEventHandler.Error"
    }

    /// Represents the various types of connection that can be created.
    public enum ConnectionType: Sendable {
        /// Connect to an embedded XPC service inside the current application’s bundle. Pass the XPC service’s bundle ID as the `bundleID` parameter.
        case remoteService(bundleID: String)
        /// Create a connection from a passed-in endpoint, which typically will come embedded in an XPC message.
        case remoteServiceFromEndpoint(XPCEndpoint)
        /// Connect to a remote Mach service by its service name.
        case remoteMachService(serviceName: String, isPrivilegedHelperTool: Bool)
    }

    /// A handler that will be called if a communication error occurs.
    ///
    /// It is called on the connection's own serial queue or on one of XPC's threads, never on the main thread.
    public typealias ErrorHandler = @Sendable (XPCConnection, any Swift.Error) -> Void

    internal final class MessageHandler: Sendable {
        typealias RawHandler = @Sendable (XPCMessageContext) async throws -> xpc_object_t
        let closure: RawHandler

        // `SendableMetatype` because the closure decodes and encodes on the connection's executor, not the caller's.
        init<Request: Decodable & SendableMetatype, Response: Encodable & SendableMetatype>(
            closure: @escaping @Sendable (XPCMessageContext, sending Request) async throws -> Response
        ) {
            self.closure = { context in
                guard let body = xpc_dictionary_get_value(context.message, MessageKeys.body) else {
                    throw Error.missingMessageBody
                }

                let request = try XPCDecoder().decode(type: Request.self, from: body)
                let response = try await closure(context, request)

                return try XPCEncoder().encode(response)
            }
        }
    }

    /// The dictionary that will answer a message, while its handler runs; `nil` for a one-way message.
    private struct PendingReply: @unchecked Sendable {
        // Unchecked because of `reply`, which only the job that handles its message touches.
        let reply: xpc_object_t?
    }

    /// A reply on its way from XPC's reply handler to the task that sent the message.
    private struct ReceivedReply: @unchecked Sendable {
        // Unchecked because of `reply`, which XPC hands over and nothing else holds.
        let reply: xpc_object_t
    }

    private let connection: xpc_connection_t
    private let dispatcher: MessageDispatcher
    private let handlers = HandlerTable()

    /// The handlers of the listener that accepted this connection, consulted after this connection's own.
    private let listenerHandlers: HandlerTable?

    /// Replaces message handling for a listener's own connection, whose events are new connections, not messages.
    private let listenerEventHandler: (@Sendable (XPCConnection, xpc_object_t) -> Void)?

    /// Initialize a new `XPCConnection`.
    ///
    /// - Parameters:
    ///   - type: The type of connection to create. See the documentation for `ConnectionType` for possible values.
    ///   - requirement: An optional requirement that the process on the other end must satisfy. If specified, the
    ///     connection will reject all messages from processes that do not meet it, and a message that waits for a reply
    ///     from such a process fails with an error.
    ///
    /// - Throws: `XPCError.invalidCodeSignatureRequirement` or `XPCError.invalidPeerRequirement` if XPC rejects
    ///   `requirement`, or any other error that comes up in the process of initializing the connection.
    public convenience init(type: ConnectionType, requirement: XPCPeerRequirement? = nil) throws {
        switch type {
        case .remoteService(let bundleID):
            try self.init(connection: xpc_connection_create(bundleID, nil), requirement: requirement)
        case .remoteServiceFromEndpoint(let endpoint):
            try self.init(connection: endpoint.makeConnection(), requirement: requirement)
        case .remoteMachService(serviceName: let name, isPrivilegedHelperTool: let isPrivileged):
            let flags: Int32 = isPrivileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0
            try self.init(machServiceName: name, flags: flags, requirement: requirement)
        }
    }

    /// Initialize a new `XPCConnection` that checks its peer against a code signing requirement.
    ///
    /// - Parameters:
    ///   - type: The type of connection to create. See the documentation for `ConnectionType` for possible values.
    ///   - requirement: An optional code signing requirement. If specified, the connection will reject all messages from processes that do not meet the specified requirement.
    ///
    /// - Throws: Any errors that come up in the process of initializing the connection.
    @available(*, deprecated, message: "Use init(type:requirement:) with requirement: .codeSigning(_:) instead.")
    public convenience init(type: ConnectionType, codeSigningRequirement requirement: String?) throws {
        try self.init(type: type, requirement: requirement.map { XPCPeerRequirement.codeSigning($0) })
    }

    internal convenience init(
        machServiceName: String,
        flags: Int32,
        requirement: XPCPeerRequirement? = nil,
        listenerEventHandler: (@Sendable (XPCConnection, xpc_object_t) -> Void)? = nil
    ) throws {
        try self.init(
            connection: xpc_connection_create_mach_service(machServiceName, nil, UInt64(flags)),
            requirement: requirement,
            listenerEventHandler: listenerEventHandler
        )
    }

    internal init(
        connection: xpc_connection_t,
        requirement: XPCPeerRequirement?,
        listenerHandlers: HandlerTable? = nil,
        listenerEventHandler: (@Sendable (XPCConnection, xpc_object_t) -> Void)? = nil,
        dispatchStrategy: MessageDispatcher.Strategy = .automatic
    ) throws {
        do {
            try requirement?.apply(to: connection)
        } catch {
            // Releasing a connection that was never activated is API misuse, which crashes the process.
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            xpc_connection_cancel(connection)

            throw error
        }

        self.connection = connection
        self.dispatcher = MessageDispatcher(label: "com.charlessoft.SwiftyXPC.XPCConnection", strategy: dispatchStrategy)
        self.listenerHandlers = listenerHandlers
        self.listenerEventHandler = listenerEventHandler

        xpc_connection_set_target_queue(connection, self.dispatcher.queue)

        // The handler keeps this object alive for as long as XPC keeps the connection, which is until it is cancelled
        // or invalidated; that is what keeps a connection that a listener accepted alive.
        xpc_connection_set_event_handler(connection) { event in
            self.handleEvent(event)
        }
    }

    /// A handler that will be called if a communication error occurs.
    ///
    /// A connection that a listener accepted uses the listener's error handler until it is given one of its own.
    public var errorHandler: ErrorHandler? {
        get { self.handlers.errorHandler ?? self.listenerHandlers?.errorHandler }
        set { self.handlers.errorHandler = newValue }
    }

    internal func messageHandler(named name: String) -> MessageHandler? {
        self.handlers.messageHandler(named: name) ?? self.listenerHandlers?.messageHandler(named: name)
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments or returning any value.
    ///
    /// Handlers can be set or replaced at any time, including after the connection has been activated.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:)`.
    ///   - handler: Pass a function that processes the message, optionally throwing an error.
    public func setMessageHandler(
        name: String,
        handler: @escaping @Sendable (XPCMessageContext) async throws -> Void
    ) {
        self.setMessageHandler(name: name) { (context: XPCMessageContext, _: XPCNull) async throws -> XPCNull in
            try await handler(context)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, taking an argument but not returning any value.
    ///
    /// Handlers can be set or replaced at any time, including after the connection has been activated.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:request:)`.
    ///   - handler: Pass a function that processes the message, optionally throwing an error. The request value must
    ///     conform to the `Decodable` protocol, and will automatically be type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Decodable & SendableMetatype>(
        name: String,
        handler: @escaping @Sendable (XPCMessageContext, sending Request) async throws -> Void
    ) {
        self.setMessageHandler(name: name) { (context: XPCMessageContext, request: sending Request) async throws -> XPCNull in
            try await handler(context, request)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments but returning a value.
    ///
    /// Handlers can be set or replaced at any time, including after the connection has been activated.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:)`.
    ///   - handler: Pass a function that processes the message and either returns a value or throws an error. The return value must
    ///     conform to the `Encodable` protocol.
    public func setMessageHandler<Response: Encodable & SendableMetatype>(
        name: String,
        handler: @escaping @Sendable (XPCMessageContext) async throws -> Response
    ) {
        self.setMessageHandler(name: name) { (context: XPCMessageContext, _: XPCNull) async throws -> Response in
            try await handler(context)
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, taking an argument and returning a value.
    ///
    /// Handlers can be set or replaced at any time, including after the connection has been activated.
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
    ///         context: XPCMessageContext,
    ///         message: String
    ///     ) async throws -> String {
    ///         self.logger.notice("Process \(context.processIdentifier) sent message: \(message)")
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
    ///   - handler: Pass a function that processes the message and either returns a value or throws an error. The request must conform to
    ///     `Decodable` and the return value to `Encodable`. The types are automatically type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Decodable & SendableMetatype, Response: Encodable & SendableMetatype>(
        name: String,
        handler: @escaping @Sendable (XPCMessageContext, sending Request) async throws -> Response
    ) {
        self.handlers.setMessageHandler(MessageHandler(closure: handler), named: name)
    }

    #if os(macOS)
    /// The audit session identifier associated with the remote process.
    ///
    /// XPC updates it whenever a message arrives. In a message handler, use the `XPCMessageContext`'s
    /// `auditSessionIdentifier`, which belongs to the message being handled.
    public var auditSessionIdentifier: au_asid_t {
        xpc_connection_get_asid(self.connection)
    }
    #endif

    /// The effective group identifier associated with the remote process.
    ///
    /// XPC updates it whenever a message arrives. In a message handler, use the `XPCMessageContext`'s
    /// `effectiveGroupIdentifier`, which belongs to the message being handled.
    public var effectiveGroupIdentifier: gid_t {
        xpc_connection_get_egid(self.connection)
    }

    /// The effective user identifier associated with the remote process.
    ///
    /// XPC updates it whenever a message arrives. In a message handler, use the `XPCMessageContext`'s
    /// `effectiveUserIdentifier`, which belongs to the message being handled.
    public var effectiveUserIdentifier: uid_t {
        xpc_connection_get_euid(self.connection)
    }

    #if os(macOS)
    /// The process ID of the remote process.
    ///
    /// XPC updates it whenever a message arrives. In a message handler, use the `XPCMessageContext`'s
    /// `processIdentifier`, which belongs to the message being handled.
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
    ///
    /// XPC updates the token whenever a message arrives, so by the time a message handler reads it, it can belong to a
    /// later message. In a message handler, use the `XPCMessageContext`'s `auditToken`, which belongs to the message
    /// being handled.
    public var auditToken: audit_token_t {
        var token = audit_token_t()
        swiftyxpc_xpc_connection_get_audit_token(self.connection, &token)
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
    public nonisolated(nonsending) func sendMessage(name: String) async throws {
        let _: XPCNull = try await self.sendMessage(name: name, request: XPCNull.shared)
    }

    /// Send a message to an `XPCConnection` in another process that takes a parameter.
    ///
    /// The request is encoded before this method suspends, in the caller's isolation domain, so it does not need to be `Sendable`.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///   - request: A parameter that will be passed to the receiving connection’s handler function. The type of the request must match the type specified by the receiving connection.
    ///
    /// - Throws: Throws an error the `request` parameter does not match the type specified by the receiving connection’s handler function,
    ///   if the receiving connection throws an error in its handler, or if a communication error occurs.
    public nonisolated(nonsending) func sendMessage(name: String, request: some Encodable) async throws {
        let _: XPCNull = try await self.sendMessage(name: name, request: request)
    }

    /// Send a message to an `XPCConnection` in another process that does not take a parameter, and receives a response.
    ///
    /// - Parameter name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///
    /// - Returns: The value returned by the receiving connection's helper function. It is decoded from the reply, so it does
    ///   not need to be `Sendable`.
    ///
    /// - Throws: Throws an error if the receiving connection throws an error in its handler, or if a communication error occurs.
    public nonisolated(nonsending) func sendMessage<Response: Decodable>(name: String) async throws -> sending Response {
        try await self.sendMessage(name: name, request: XPCNull.shared)
    }

    /// Send a message to an `XPCConnection` in another process that takes a parameter.
    ///
    /// The request is encoded before this method suspends, in the caller's isolation domain, so it does not need to be `Sendable`.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///   - request: A parameter that will be passed to the receiving connection’s handler function. The type of the request must match the type specified by the receiving connection.
    ///
    /// - Returns: The value returned by the receiving connection's helper function. It is decoded from the reply, so it does
    ///   not need to be `Sendable`.
    ///
    /// - Throws: Throws an error the `request` parameter does not match the type specified by the receiving connection’s handler function,
    ///   if the receiving connection throws an error in its handler, or if a communication error occurs.
    public nonisolated(nonsending) func sendMessage<Response: Decodable>(
        name: String,
        request: some Encodable
    ) async throws -> sending Response {
        let message = self.makeMessage(name: name, body: try XPCEncoder().encode(request))

        let receivedReply = await withCheckedContinuation { (continuation: CheckedContinuation<ReceivedReply, Never>) in
            xpc_connection_send_message_with_reply(self.connection, message, nil) { reply in
                continuation.resume(returning: ReceivedReply(reply: reply))
            }
        }

        // Decoded here, in the caller's isolation domain, rather than on XPC's thread, so the response type does not
        // have to be usable from another thread.
        return try self.decodeReply(receivedReply.reply, as: Response.self)
    }

    /// Send a message, and do not wait for a reply.
    ///
    /// The receiving connection's handler does not answer a one-way message: whatever it returns is discarded, and an
    /// error it throws goes to the receiving connection's `errorHandler`, not to this one.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the receiving connection has passed to `setMessage(name:handler:)`.
    ///   - message: A parameter that will be passed to the receiving connection’s handler function. This must match the type specified in the receiving connection’s handler function.
    ///
    /// - Throws: Any errors that occur in the process of encoding the message.
    public func sendOnewayMessage(name: String, message: some Encodable) throws {
        xpc_connection_send_message(self.connection, self.makeMessage(name: name, body: try XPCEncoder().encode(message)))
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
    public func sendBarrier(_ barrier: @escaping @Sendable () -> Void) {
        xpc_connection_send_barrier(self.connection, barrier)
    }

    /// Converts an XPC error event that this connection delivered, with the reason if XPC invalidated the connection.
    internal func error(fromEvent event: xpc_object_t) -> XPCError {
        XPCError(error: event, connection: self.connection)
    }

    private func makeMessage(name: String, body: xpc_object_t) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)

        xpc_dictionary_set_string(message, MessageKeys.name, name)
        xpc_dictionary_set_value(message, MessageKeys.body, body)

        return message
    }

    private func decodeReply<Response: Decodable>(
        _ reply: xpc_object_t,
        as responseType: Response.Type
    ) throws -> sending Response {
        switch reply.type {
        case .dictionary:
            break
        case .error:
            throw XPCError(error: reply, connection: self.connection)
        default:
            throw Error.typeMismatch(expected: .dictionary, actual: reply.type)
        }

        if let error = xpc_dictionary_get_value(reply, MessageKeys.error) {
            throw try XPCErrorRegistry.shared.decodeError(error)
        }

        guard let body = xpc_dictionary_get_value(reply, MessageKeys.body) else {
            throw Error.missingMessageBody
        }

        if Response.self == XPCNull.self {
            // A caller that asked for no response accepts whatever the handler returned.
            return XPCNull.shared as! Response
        }

        return try XPCDecoder().decode(type: Response.self, from: body)
    }

    // Runs on the dispatcher's queue, which XPC uses as this connection's target queue.
    private func handleEvent(_ event: xpc_object_t) {
        if let listenerEventHandler = self.listenerEventHandler {
            listenerEventHandler(self, event)
            return
        }

        switch event.type {
        case .dictionary:
            self.receive(event)
        case .error:
            self.reportError(self.error(fromEvent: event))
        default:
            self.reportError(Error.typeMismatch(expected: .dictionary, actual: event.type))
        }
    }

    private func receive(_ message: xpc_object_t) {
        if let encodedError = xpc_dictionary_get_value(message, MessageKeys.error) {
            // SwiftyXPC 0.5 sends the error of a one-way message's handler back to its sender as a message of its own.
            do {
                self.reportError(try XPCErrorRegistry.shared.decodeError(encodedError))
            } catch {
                self.reportError(error)
            }

            return
        }

        let reply = xpc_dictionary_create_reply(message)

        let messageName: String
        let handler: MessageHandler

        do {
            guard let name = xpc_dictionary_get_value(message, MessageKeys.name).flatMap({ String($0) }) else {
                throw Error.missingMessageName
            }

            guard let namedHandler = self.messageHandler(named: name) else {
                throw Error.unexpectedMessage
            }

            messageName = name
            handler = namedHandler
        } catch {
            // This side learns that it was sent a message it cannot route. A sender that is waiting for a reply learns
            // why it will not get the one it wanted, instead of seeing the connection as interrupted.
            self.reportError(error)
            self.complete(PendingReply(reply: reply), with: .failure(error), reportingUnansweredFailure: false)
            return
        }

        let context = XPCMessageContext(
            connection: self,
            message: message,
            messageName: messageName,
            expectsReply: reply != nil
        )
        let pendingReply = PendingReply(reply: reply)

        self.dispatcher.dispatch(
            MessageDispatcher.Job {
                let result: Result<xpc_object_t, any Swift.Error>

                do {
                    result = .success(try await handler.closure(context))
                } catch {
                    result = .failure(error)
                }

                self.complete(pendingReply, with: result, reportingUnansweredFailure: true)
            }
        )
    }

    /// Answers a message with `result`, if its sender is waiting for a reply.
    ///
    /// A one-way message gets no answer at all. If `reportingUnansweredFailure` is `true`, an error that therefore
    /// reaches nobody is reported to this side's error handler instead.
    private func complete(
        _ pendingReply: PendingReply,
        with result: Result<xpc_object_t, any Swift.Error>,
        reportingUnansweredFailure: Bool
    ) {
        guard let reply = pendingReply.reply else {
            if reportingUnansweredFailure, case .failure(let error) = result {
                self.reportError(error)
            }

            return
        }

        switch result {
        case .success(let body):
            xpc_dictionary_set_value(reply, MessageKeys.body, body)
        case .failure(let error):
            xpc_dictionary_set_value(reply, MessageKeys.error, self.encodeForReply(error))
        }

        xpc_connection_send_message(self.connection, reply)
    }

    /// Encodes `error` for a reply, falling back to its domain and code if the error itself fails to encode.
    private func encodeForReply(_ error: any Swift.Error) -> xpc_object_t {
        do {
            return try XPCErrorRegistry.shared.encodeError(error)
        } catch let encodingError {
            // The sender still learns which error it was; this side learns why the details were lost.
            self.reportError(encodingError)

            return XPCErrorRegistry.shared.encodeErrorWithoutPayload(error)
        }
    }

    private func reportError(_ error: any Swift.Error) {
        self.errorHandler?(self, error)
    }
}
#endif
