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
                .define("_ISOC99_SOURCE")
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
