// swift-tools-version: 6.2

import PackageDescription

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
            dependencies: ["OpenCastVoiceBoostC"]
        ),
        .target(
            name: "VoiceBoostLabSupport",
            dependencies: ["OpenCastVoiceBoost"]
        ),
        .executableTarget(
            name: "VoiceBoostLab",
            dependencies: ["VoiceBoostLabSupport"]
        ),
        .testTarget(
            name: "OpenCastVoiceBoostTests",
            dependencies: [
                "OpenCastVoiceBoost",
                "VoiceBoostLabSupport"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
