#if os(macOS) || targetEnvironment(macCatalyst)
//
//  MessageHandlerTable.swift
//  SwiftyXPC
//

import os

/// The message handlers a connection or a listener answers with, behind a lock.
///
/// A reference type so a listener and every connection it accepts can share
/// one: a connection looks a handler up in its listener's table when a
/// message arrives, so a handler the listener gains — or replaces — after
/// accepting the connection still reaches it.
internal final class MessageHandlerTable: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var handlers: [String: XPCConnection.MessageHandler] = [:]

    init() {
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    subscript(name: String) -> XPCConnection.MessageHandler? {
        get {
            os_unfair_lock_lock(self.lock)
            defer { os_unfair_lock_unlock(self.lock) }
            return self.handlers[name]
        }
        set {
            os_unfair_lock_lock(self.lock)
            defer { os_unfair_lock_unlock(self.lock) }
            self.handlers[name] = newValue
        }
    }
}
#endif
