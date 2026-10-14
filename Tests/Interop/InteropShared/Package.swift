// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "InteropShared",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "InteropShared", targets: ["InteropShared"])
    ],
    targets: [
        .target(name: "InteropShared")
    ]
)
