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
        .library(name: "AetherKit", targets: ["ByteKit", "TagKit"]),
    ],
    targets: [
        .target(name: "ByteKit", swiftSettings: settings),
        .testTarget(name: "ByteKitTests", dependencies: ["ByteKit"], swiftSettings: settings),
        .target(name: "TagKit", dependencies: ["ByteKit"], swiftSettings: settings),
        .testTarget(name: "TagKitTests", dependencies: ["TagKit"], swiftSettings: settings),
    ]
)
