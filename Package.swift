// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Concurrency behaviour that a future language mode will make the default, adopted now by every target.
///
/// With `NonisolatedNonsendingByDefault`, a nonisolated async function runs on its caller's executor unless it is
/// marked `@concurrent`. Message handlers therefore run on their connection's serial executor.
let futureConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

/// Every feature of the Swift 6 language mode except `ImportObjcForwardDeclarations`, for the library target.
///
/// Swift 6.4 crashes in IR generation when a module that does not import Foundation needs type metadata for an XPC
/// object type — a stored `xpc_object_t`, an array or optional of one passed to generic code, a cast to one — while
/// `ImportObjcForwardDeclarations` (SE-0384) is on: `NSObject`'s `description` returns an `NSString` that only
/// Foundation defines. The Swift 6 language mode cannot switch that one feature off, so the library stays in the
/// Swift 5 mode and turns on everything else the Swift 6 mode would, which keeps the full data-race checking.
/// See Documentations/Evolutions/draft-swift-concurrency-1-0.md.
let swift6FeaturesExceptForwardDeclarations: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("DeprecateApplicationMain"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("IsolatedDefaultValues"),
    .enableUpcomingFeature("GlobalConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("ImplicitOpenExistentials"),
    .enableUpcomingFeature("RegionBasedIsolation"),
    .enableUpcomingFeature("DynamicActorIsolation"),
    .enableUpcomingFeature("NonfrozenEnumExhaustivity"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
]

let package = Package(
    name: "SwiftyXPC",
    platforms: [
        .macOS(.v12),
        .macCatalyst(.v15),
    ],
    products: [
        .library(
            name: "SwiftyXPC",
            targets: ["SwiftyXPC"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftyXPC",
            dependencies: [],
            swiftSettings: swift6FeaturesExceptForwardDeclarations + futureConcurrencySettings
        ),
        .target(
            name: "TestShared",
            dependencies: ["SwiftyXPC"],
            swiftSettings: futureConcurrencySettings
        ),
        .executableTarget(
            name: "TestHelper",
            dependencies: ["SwiftyXPC", "TestShared"],
            swiftSettings: futureConcurrencySettings
        ),
        .testTarget(
            name: "SwiftyXPCTests",
            dependencies: ["SwiftyXPC", "TestHelper", "TestShared"],
            swiftSettings: futureConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
