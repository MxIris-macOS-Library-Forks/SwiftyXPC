// The messages that both versions of the test helper understand, with the same wire format as `Sources/TestShared`.
//
// The interoperability clients cannot use `TestShared`, which depends on one particular version of SwiftyXPC, so these
// declarations repeat its types field for field. Error types are registered under the domains the helper uses, which
// name `TestShared`, not this module.

import Foundation

public let helperID = "com.charlessoft.SwiftyXPC.TestHelper"

public enum CommandSet {
    public static let reportIDs = "com.charlessoft.SwiftyXPC.Tests.ReportIDs"
    public static let capitalizeString = "com.charlessoft.SwiftyXPC.Tests.CapitalizeString"
    public static let multiplyBy5 = "com.charlessoft.SwiftyXPC.Tests.MultiplyBy5"
    public static let transportData = "com.charlessoft.SwiftyXPC.Tests.TransportData"
    public static let tellAJoke = "com.charlessoft.SwiftyXPC.Tests.TellAJoke"
    public static let pauseOneSecond = "com.charlessoft.SwiftyXPC.Tests.PauseOneSecond"
}

public struct ProcessIDs: Codable, Sendable {
    public let pid: pid_t
    public let effectiveUID: uid_t
    public let effectiveGID: gid_t
    public let auditSessionID: au_asid_t
}

public struct DataInfo: Codable, Sendable {
    public struct DataError: Error, Codable {
        /// The domain the helper's `TestShared.DataInfo.DataError` travels under.
        public static let domain = "TestShared.DataInfo.DataError"

        public let failureReason: String?
    }

    public let characterName: Data
    public let playedBy: Data
    public let otherCharacters: [Data]
}

public enum JokeMessage {
    public struct NotAKnockKnockJoke: Error, Codable {
        /// The domain the helper's `TestShared.JokeMessage.NotAKnockKnockJoke` travels under.
        public static let domain = "TestShared.JokeMessage.NotAKnockKnockJoke"

        public let complaint: String
    }

    public static let askForJoke = "ask-for-joke"
    public static let whosThere = "who's-there"
    public static let who = "who"
    public static let groan = "groan"
}

/// Runs named checks, printing `PASS` or `FAIL` for each, and counts the failures.
public final class CheckRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var failureCount = 0

    public init() {}

    public var failures: Int {
        self.lock.withLock { self.failureCount }
    }

    public func check(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            print("PASS \(name)")
        } catch {
            self.lock.withLock { self.failureCount += 1 }
            print("FAIL \(name): \(error)")
        }
    }
}

/// A failed expectation in a check.
public struct Mismatch: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public func expect(_ condition: Bool, _ description: @autoclosure () -> String) throws {
    if !condition {
        throw Mismatch(description())
    }
}

/// Collects values from any thread.
public final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    public init() {}

    public var values: [Element] {
        self.lock.withLock { self.storage }
    }

    public func record(_ value: Element) {
        self.lock.withLock { self.storage.append(value) }
    }

    /// Waits until at least `count` values have been recorded, or `timeout` seconds have passed.
    public func waitUntil(count: Int, timeout: TimeInterval = 10) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)

        while self.values.count < count {
            if Date.now >= deadline {
                throw Mismatch("timed out with \(self.values.count) of \(count) values: \(self.values)")
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
