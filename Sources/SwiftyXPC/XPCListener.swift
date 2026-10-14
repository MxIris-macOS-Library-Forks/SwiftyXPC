#if os(macOS) || targetEnvironment(macCatalyst)
//
//  XPCListener.swift
//  SwiftyXPC
//
//  Created by Charles Srstka on 8/8/21.
//

import System
import XPC
import os

/// A listener that waits for new incoming connections, configures them, and accepts or rejects them.
///
/// Each XPC service, launchd agent, or launchd daemon typically has at least one `XPCListener` object that listens for connections to a specified service name.
///
/// Create an `XPCListener` via `init(type:requirement:)`.
///
/// Use the `setMessageHandler` family of functions to set up handler functions to receive messages.
///
/// A listener must receive `.activate()` before it can receive any messages.
///
/// Every connection the listener accepts uses the listener's message handlers and error handler, including handlers
/// that are set after the connection was accepted. Each accepted connection has its own serial executor; see
/// `XPCConnection` for how its handlers run.
public final class XPCListener: Sendable {
    /// The type of the listener.
    public enum ListenerType: Sendable {
        /// An anonymous listener connection. This can be passed to other processes by embedding its `endpoint` in an XPC message.
        case anonymous
        /// A service listener used to listen for incoming connections in an embedded XPC service. Requires the service’s `Info.plist` to be configured correctly.
        case service
        /// A service listener used to listen for incoming connections in a Mach service, advertised to the system by the given `name`.
        case machService(name: String)
    }

    private enum Backing: Sendable {
        /// `xpc_main` accepts the connections; there is no listener connection.
        case xpcMain
        /// A listener connection, whose events are the connections to accept.
        case connection(XPCConnection)
    }

    /// The type of this listener.
    public let type: ListenerType
    private let backing: Backing

    /// The message handlers and error handler that every accepted connection uses.
    private let handlers: HandlerTable

    private let requirement: XPCPeerRequirement?
    private let peerDispatchStrategy: MessageDispatcher.Strategy

    // `xpc_main` takes a C function that can't capture any context, so the `.service` listener is stored globally.
    private static let xpcMainListener = LockedState<XPCListener?>.make(nil)

    /// Returns an endpoint object that may be sent over an existing connection.
    ///
    /// The receiver of the endpoint can use this object to create a new connection to this `XPCListener` object.
    /// The resulting `XPCEndpoint` object uniquely names this listener object across connections.
    public var endpoint: XPCEndpoint {
        switch self.backing {
        case .xpcMain:
            fatalError("Can't get endpoint for main service listener")
        case .connection(let connection):
            return connection.makeEndpoint()
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments or returning any value.
    ///
    /// Handlers can be set or replaced at any time, including after the listener has been activated; they apply to
    /// connections that the listener has already accepted, too.
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
    /// Handlers can be set or replaced at any time, including after the listener has been activated; they apply to
    /// connections that the listener has already accepted, too.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:request:)`.
    ///   - handler: Pass a function that processes the message, optionally throwing an error. The request value must
    ///     conform to the `Decodable` protocol, and will automatically be type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Decodable & SendableMetatype>(
        name: String,
        handler: @escaping @Sendable (XPCMessageContext, sending Request) async throws -> Void
    ) {
        self.setMessageHandler(name: name) {
            (context: XPCMessageContext, request: sending Request) async throws -> XPCNull in
            try await handler(context, request)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments but returning a value.
    ///
    /// Handlers can be set or replaced at any time, including after the listener has been activated; they apply to
    /// connections that the listener has already accepted, too.
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
    /// Handlers can be set or replaced at any time, including after the listener has been activated; they apply to
    /// connections that the listener has already accepted, too.
    ///
    /// Example usage:
    ///
    ///     listener.setMessageHandler(
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
        self.handlers.setMessageHandler(XPCConnection.MessageHandler(closure: handler), named: name)
    }

    /// A handler that will be called if a communication error occurs.
    ///
    /// It receives errors of the listener itself, with the listener's own connection, and errors of every accepted
    /// connection that has no error handler of its own, with that connection.
    public var errorHandler: XPCConnection.ErrorHandler? {
        get { self.handlers.errorHandler }
        set { self.handlers.errorHandler = newValue }
    }

    /// Create a new `XPCListener`.
    ///
    /// - Parameters:
    ///   - type: The type of listener to create. Check the documentation for `ListenerType` for possible values.
    ///   - requirement: An optional requirement that every connecting process must satisfy. If specified, the
    ///     listener will reject all messages from processes that do not meet it.
    ///
    /// - Throws: `XPCError.invalidCodeSignatureRequirement` or `XPCError.invalidPeerRequirement` if XPC rejects
    ///   `requirement`, or any other error that comes up in the process of creating the listener.
    public convenience init(type: ListenerType, requirement: XPCPeerRequirement? = nil) throws {
        try self.init(type: type, requirement: requirement, peerDispatchStrategy: .automatic)
    }

    /// Create a new `XPCListener` that checks every connecting process against a code signing requirement.
    ///
    /// - Parameters:
    ///   - type: The type of listener to create. Check the documentation for `ListenerType` for possible values.
    ///   - requirement: An optional code signing requirement. If specified, the listener will reject all messages from processes that do not meet the specified requirement.
    ///
    /// - Throws: Any errors that come up in the process of creating the listener.
    @available(*, deprecated, message: "Use init(type:requirement:) with requirement: .codeSigning(_:) instead.")
    public convenience init(type: ListenerType, codeSigningRequirement requirement: String?) throws {
        try self.init(type: type, requirement: requirement.map { XPCPeerRequirement.codeSigning($0) })
    }

    internal init(
        type: ListenerType,
        requirement: XPCPeerRequirement?,
        peerDispatchStrategy: MessageDispatcher.Strategy
    ) throws {
        let handlers = HandlerTable()
        let acceptConnection = Self.makeConnectionAcceptor(
            handlers: handlers,
            requirement: requirement,
            peerDispatchStrategy: peerDispatchStrategy
        )

        self.type = type
        self.handlers = handlers
        self.requirement = requirement
        self.peerDispatchStrategy = peerDispatchStrategy

        // The requirement goes on the listener's own connection, where XPC applies it to every peer, and on each
        // accepted connection as well.
        switch type {
        case .anonymous:
            self.backing = .connection(
                try XPCConnection(
                    connection: xpc_connection_create(nil, nil),
                    requirement: requirement,
                    listenerEventHandler: acceptConnection
                )
            )
        case .service:
            self.backing = .xpcMain
        case .machService(let name):
            self.backing = .connection(
                try XPCConnection(
                    machServiceName: name,
                    flags: XPC_CONNECTION_MACH_SERVICE_LISTENER,
                    requirement: requirement,
                    listenerEventHandler: acceptConnection
                )
            )
        }

        if case .xpcMain = self.backing {
            Self.xpcMainListener.withLock { $0 = self }
        }
    }

    /// Returns the event handler of a listener's own connection, whose events are the connections to accept.
    ///
    /// It captures the listener's parts rather than the listener, which does not exist yet when its connection is made.
    private static func makeConnectionAcceptor(
        handlers: HandlerTable,
        requirement: XPCPeerRequirement?,
        peerDispatchStrategy: MessageDispatcher.Strategy
    ) -> @Sendable (XPCConnection, xpc_object_t) -> Void {
        { listenerConnection, event in
            // A listener connection delivers two kinds of events: a brand-new peer connection to accept, or an error
            // object (for example XPC_ERROR_CONNECTION_INVALID when the listener itself is cancelled, or
            // XPC_ERROR_TERMINATION_IMMINENT during shutdown). Only genuine peer connections may be turned into an
            // XPCConnection; every other event is a listener-level condition that must be surfaced through
            // `errorHandler`. Trapping here would escalate a routine listener teardown into a process-wide abort.
            guard case .connection = event.type else {
                handlers.errorHandler?(listenerConnection, listenerConnection.error(fromEvent: event))
                return
            }

            do {
                try Self.accept(
                    event,
                    handlers: handlers,
                    requirement: requirement,
                    peerDispatchStrategy: peerDispatchStrategy
                )
            } catch {
                handlers.errorHandler?(listenerConnection, error)
            }
        }
    }

    private static func accept(
        _ peer: xpc_connection_t,
        handlers: HandlerTable,
        requirement: XPCPeerRequirement?,
        peerDispatchStrategy: MessageDispatcher.Strategy
    ) throws {
        let connection = try XPCConnection(
            connection: peer,
            requirement: requirement,
            listenerHandlers: handlers,
            dispatchStrategy: peerDispatchStrategy
        )

        connection.activate()
    }

    /// Cancels the listener and ensures that its event handler doesn't fire again.
    ///
    /// After this call, any messages that have not yet been sent will be discarded, and the connection will be unwound.
    /// If there are messages that are awaiting replies, they will receive the `XPCError.connectionInvalid` error.
    public func cancel() {
        switch self.backing {
        case .xpcMain:
            fatalError("XPC service listener cannot be cancelled")
        case .connection(let connection):
            connection.cancel()
        }
    }

    /// Activate the connection.
    ///
    /// Listeners start in an inactive state, so you must call `activate()` on a connection before it will send or receive any messages.
    ///
    /// For a `.service` listener this calls `xpc_main`, which never returns.
    public func activate() {
        switch self.backing {
        case .xpcMain:
            xpc_main { peer in
                guard let listener = XPCListener.xpcMainListener.value else {
                    os_log(.fault, "No XPC service listener to accept an incoming XPC connection!")
                    return
                }

                do {
                    try XPCListener.accept(
                        peer,
                        handlers: listener.handlers,
                        requirement: listener.requirement,
                        peerDispatchStrategy: listener.peerDispatchStrategy
                    )
                } catch {
                    os_log(.fault, "Can’t initialize incoming XPC connection!")
                }
            }
        case .connection(let connection):
            connection.activate()
        }
    }

    /// Suspends the listener so that the event handler block doesn't fire and the listener doesn't attempt to send any messages it has in its queue.
    ///
    /// All calls to `suspend()` must be balanced with calls to `resume()` before releasing the last reference to the listener.
    ///
    /// Suspension is asynchronous and non-preemptive, and therefore this method will not interrupt the execution of an already-running event handler block.
    /// If the event handler is executing at the time of this call, it will finish, and then the listener will be suspended before the next scheduled invocation of
    /// the event handler. The XPC runtime guarantees this non-preemptiveness even for concurrent target queues.
    ///
    /// Listeners initialized with the `.service` type cannot be suspended, so calling `.suspend()` on these listeners is considered an error.
    public func suspend() {
        switch self.backing {
        case .xpcMain:
            fatalError("XPC service listener cannot be suspended")
        case .connection(let connection):
            connection.suspend()
        }
    }

    /// Resumes a suspended listener.
    ///
    /// In order for a listener to become live, every call to `suspend()` must be balanced with a call to `resume()`.
    /// Calling `resume()` more times than `suspend()` has been called is considered an error.
    ///
    /// Listeners initialized with the `.service` type cannot be suspended, so calling `.resume()` on these listeners is considered an error.
    public func resume() {
        switch self.backing {
        case .xpcMain:
            fatalError("XPC service listener cannot be resumed")
        case .connection(let connection):
            connection.resume()
        }
    }
}
#endif
