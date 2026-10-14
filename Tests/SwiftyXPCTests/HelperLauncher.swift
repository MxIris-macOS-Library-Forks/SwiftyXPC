#if os(macOS) || targetEnvironment(macCatalyst)
//
//  HelperLauncher.swift
//
//
//  Created by Charles Srstka on 10/12/23.
//

import Foundation
import System
import TestShared
import Testing

final class HelperLauncher: Sendable {
    let codeSigningRequirement: String
    private let plistURL: URL

    private struct LoadError: Error {}

    init() throws {
        let bundleURL = Bundle(for: Self.self).bundleURL
        let helperURL = bundleURL.deletingLastPathComponent().appending(path: "TestHelper")

        self.plistURL = try Self.writeLaunchdPlist(helperURL: helperURL)
        self.codeSigningRequirement = try Self.getCodeSigningRequirement(url: helperURL)
    }

    func startHelper() throws {
        do {
            try self.runLaunchctl(verb: "load")
        } catch is LoadError {
            try self.runLaunchctl(verb: "unload")
            try self.runLaunchctl(verb: "load")
        }
    }

    func stopHelper() throws {
        try self.runLaunchctl(verb: "unload")
        try? FileManager.default.removeItem(at: self.plistURL)
    }

    private func runLaunchctl(verb: String) throws {
        let process = Process()
        let stderrPipe = Pipe()
        let stderrHandle = stderrPipe.fileHandleForReading

        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = [verb, self.plistURL.path]
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if let stderrData = try stderrHandle.readToEnd(),
            let stderr = String(data: stderrData, encoding: .utf8),
            stderr.contains("Load failed:")
        {
            throw LoadError()
        }
    }

    private static func writeLaunchdPlist(helperURL: URL) throws -> URL {
        let plist: [String: Any] = [
            "KeepAlive": true,
            "Label": helperID,
            "MachServices": [helperID: true],
            "Program": helperURL.path,
            "RunAtLoad": true,
        ]

        let plistURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        try (plist as NSDictionary).write(to: plistURL)

        return plistURL
    }

    private static func getCodeSigningRequirement(url: URL) throws -> String {
        var staticCode: SecStaticCode? = nil
        var err = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        if err != errSecSuccess { throw Errno(rawValue: err) }

        var req: SecRequirement? = nil
        err = SecCodeCopyDesignatedRequirement(staticCode!, [], &req)
        if err != errSecSuccess { throw Errno(rawValue: err) }

        var string: CFString? = nil
        err = SecRequirementCopyString(req!, [], &string)
        if err != errSecSuccess { throw Errno(rawValue: err) }

        return string! as String
    }
}

/// Loads the `TestHelper` Mach service into launchd for as long as the suite it is applied to runs.
struct LaunchedTestHelper: SuiteTrait, TestScoping {
    /// The launcher for the helper that the running suite talks to.
    @TaskLocal static var current: HelperLauncher?

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let launcher = try HelperLauncher()
        try launcher.startHelper()

        do {
            try await Self.$current.withValue(launcher) {
                try await function()
            }
        } catch {
            try? launcher.stopHelper()
            throw error
        }

        try launcher.stopHelper()
    }
}

extension Trait where Self == LaunchedTestHelper {
    /// Loads the `TestHelper` Mach service into launchd around the suite.
    static var launchedTestHelper: Self { Self() }
}
#endif
