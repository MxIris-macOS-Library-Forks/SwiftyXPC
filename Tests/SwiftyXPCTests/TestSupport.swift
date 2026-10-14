#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import SwiftyXPC

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

    /// Whether this is `.connectionInvalid`.
    var isConnectionInvalid: Bool {
        if case .connectionInvalid = self {
            return true
        }

        return false
    }
}
#endif
