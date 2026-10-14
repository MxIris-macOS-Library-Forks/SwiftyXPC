#if os(macOS) || targetEnvironment(macCatalyst)
/// The message handlers and error handler of a connection or a listener, safe to read and change from any thread.
///
/// A listener shares its table with every connection it accepts. Each accepted connection also has a table of its own,
/// which it consults first, so a handler set on the listener reaches connections accepted before it was set.
internal final class HandlerTable: Sendable {
    private struct Contents: Sendable {
        var messageHandlers: [String: XPCConnection.MessageHandler] = [:]
        var errorHandler: XPCConnection.ErrorHandler? = nil
    }

    private let contents = LockedState.make(Contents())

    var errorHandler: XPCConnection.ErrorHandler? {
        get { self.contents.withLock { $0.errorHandler } }
        set { self.contents.withLock { $0.errorHandler = newValue } }
    }

    func messageHandler(named name: String) -> XPCConnection.MessageHandler? {
        self.contents.withLock { $0.messageHandlers[name] }
    }

    func setMessageHandler(_ handler: XPCConnection.MessageHandler, named name: String) {
        self.contents.withLock { $0.messageHandlers[name] = handler }
    }
}
#endif
