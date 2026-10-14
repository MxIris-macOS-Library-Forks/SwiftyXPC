// swift-tools-version:6.2

import Foundation
import PackageDescription

// SwiftyXPC as of this checkout, talking to the 0.5.105 test helper.
//
// A path dependency's identity is the name of its directory, which differs between checkouts (a worktree is named
// after its purpose), so it is read from the path rather than spelled out.
let swiftyXPCDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../..")
    .standardizedFileURL
let swiftyXPCPackage = swiftyXPCDirectory.lastPathComponent

let package = Package(
    name: "CurrentClient",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: swiftyXPCDirectory.path),
        .package(path: "../InteropShared"),
    ],
    targets: [
        .executableTarget(
            name: "CurrentClient",
            dependencies: [
                .product(name: "SwiftyXPC", package: swiftyXPCPackage),
                .product(name: "InteropShared", package: "InteropShared"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
