#if os(macOS) || targetEnvironment(macCatalyst)
import Synchronization
import os

/// Mutable state shared between threads, guarded by the best lock the running system provides.
///
/// macOS 15 and later use `Mutex`. Earlier systems use an `os_unfair_lock` on the heap, which is the lock `Mutex`
/// itself wraps on Darwin. `make(_:)` picks one; the subclasses are never named directly.
///
/// The lock is not recursive: `body` must not call back into the same `LockedState`. Keep `body` short, and never
/// call code you do not control from inside it.
internal class LockedState<State: Sendable>: @unchecked Sendable {
    /// Creates a lock around `initialState`.
    static func make(_ initialState: State) -> LockedState<State> {
        if #available(macOS 15.0, macCatalyst 18.0, *) {
            return MutexLockedState(initialState)
        } else {
            return UnfairLockedState(initialState)
        }
    }

    fileprivate init() {}

    /// Runs `body` with exclusive access to the state, and returns what it returns.
    func withLock<Result: Sendable, Failure: Error>(
        _ body: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        preconditionFailure("LockedState must be created with make(_:)")
    }
}

extension LockedState {
    /// A copy of the state, read under the lock.
    var value: State {
        self.withLock { $0 }
    }
}

@available(macOS 15.0, macCatalyst 18.0, *)
private final class MutexLockedState<State: Sendable>: LockedState<State>, @unchecked Sendable {
    private let mutex: Mutex<State>

    init(_ initialState: State) {
        self.mutex = Mutex(initialState)
        super.init()
    }

    override func withLock<Result: Sendable, Failure: Error>(
        _ body: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try self.mutex.withLock { (state: inout sending State) throws(Failure) -> Result in
            try body(&state)
        }
    }
}

private final class UnfairLockedState<State: Sendable>: LockedState<State>, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var state: State

    init(_ initialState: State) {
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        self.state = initialState
        super.init()
    }

    deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    override func withLock<Result: Sendable, Failure: Error>(
        _ body: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }

        return try body(&self.state)
    }
}
#endif
