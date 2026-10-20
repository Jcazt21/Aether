// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "AetherKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AetherKit", targets: ["ByteKit", "TagKit", "FlacKit", "HiFiClient"]),
    ],
    targets: [
        .target(name: "ByteKit", swiftSettings: settings),
        .testTarget(name: "ByteKitTests", dependencies: ["ByteKit"], swiftSettings: settings),
        .target(name: "TagKit", dependencies: ["ByteKit"], swiftSettings: settings),
        .testTarget(name: "TagKitTests", dependencies: ["TagKit"], swiftSettings: settings),
        .target(name: "FlacKit", dependencies: ["ByteKit", "TagKit"], swiftSettings: settings),
        .target(name: "TestSupport", dependencies: ["TagKit"], path: "Tests/TestSupport", swiftSettings: settings),
        .testTarget(name: "FlacKitTests", dependencies: ["FlacKit", "TagKit", "TestSupport"], swiftSettings: settings),
        .target(name: "HiFiClient", dependencies: ["TagKit"], swiftSettings: settings),
        .testTarget(name: "HiFiClientTests", dependencies: ["HiFiClient", "TestSupport"], swiftSettings: settings),
    ]
)
