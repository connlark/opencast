// swift-tools-version: 6.3

import PackageDescription

let swift63Settings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "OpenCastPlayback",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenCastPlayback", targets: ["OpenCastPlayback"])
    ],
    dependencies: [
        .package(path: "../OpenCastCore"),
        .package(path: "../OpenCastVoiceBoost")
    ],
    targets: [
        .target(
            name: "OpenCastPlayback",
            dependencies: [
                .product(name: "OpenCastCore", package: "OpenCastCore"),
                .product(name: "OpenCastVoiceBoost", package: "OpenCastVoiceBoost")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ] + swift63Settings
        ),
        .testTarget(
            name: "OpenCastPlaybackTests",
            dependencies: [
                "OpenCastPlayback",
                .product(name: "OpenCastCore", package: "OpenCastCore"),
                .product(name: "OpenCastVoiceBoost", package: "OpenCastVoiceBoost")
            ],
            swiftSettings: swift63Settings
        )
    ],
    swiftLanguageModes: [.v6]
)
