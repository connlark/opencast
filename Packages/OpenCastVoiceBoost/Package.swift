// swift-tools-version: 6.3

import PackageDescription

let swift63Settings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "OpenCastVoiceBoost",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenCastVoiceBoost", targets: ["OpenCastVoiceBoost"]),
        .executable(name: "VoiceBoostLab", targets: ["VoiceBoostLab"])
    ],
    targets: [
        .target(
            name: "OpenCastVoiceBoostC",
            publicHeadersPath: "include",
            cSettings: [
                .define("_ISOC99_SOURCE"),
                // Debug builds must stay representative for audio-thread cost:
                // -O0 made boost-on DSP ~10x more expensive than Release in the
                // simulator (Pass 1 baseline). Local package, so unsafeFlags is allowed.
                .unsafeFlags(["-O2"], .when(configuration: .debug))
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(
            name: "OpenCastVoiceBoost",
            dependencies: ["OpenCastVoiceBoostC"],
            swiftSettings: swift63Settings
        ),
        .target(
            name: "VoiceBoostLabSupport",
            dependencies: ["OpenCastVoiceBoost"],
            swiftSettings: swift63Settings
        ),
        .executableTarget(
            name: "VoiceBoostLab",
            dependencies: ["VoiceBoostLabSupport"],
            swiftSettings: swift63Settings
        ),
        .testTarget(
            name: "OpenCastVoiceBoostTests",
            dependencies: [
                "OpenCastVoiceBoost",
                "VoiceBoostLabSupport"
            ],
            swiftSettings: swift63Settings
        )
    ],
    swiftLanguageModes: [.v6]
)
