// swift-tools-version:5.10

import PackageDescription

// SwiftyXPC 0.5.105, the last release before 1.0, talking to the 1.0 test helper.
let package = Package(
    name: "LegacyClient",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC", exact: "0.5.105"),
        .package(path: "../InteropShared"),
    ],
    targets: [
        .executableTarget(
            name: "LegacyClient",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "InteropShared", package: "InteropShared"),
            ]
        )
    ]
)
