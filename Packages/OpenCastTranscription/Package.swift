// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenCastTranscription",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenCastTranscription", targets: ["OpenCastTranscription"]),
        .executable(name: "OpenCastTranscriptionExport", targets: ["OpenCastTranscriptionExport"])
    ],
    targets: [
        .target(
            name: "ArgmaxCore",
            swiftSettings: vendoredArgmaxSwiftSettings()
        ),
        .target(
            name: "WhisperKit",
            dependencies: ["ArgmaxCore"],
            swiftSettings: vendoredArgmaxSwiftSettings()
        ),
        .target(
            name: "OpenCastTranscription",
            dependencies: ["WhisperKit"],
            exclude: [
                "Resources/Models",
                "Resources/Tokenizers"
            ],
            resources: [
                .copy("Resources/Licenses")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "OpenCastTranscriptionExport",
            dependencies: ["OpenCastTranscription"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OpenCastTranscriptionTests",
            dependencies: [
                "ArgmaxCore",
                "WhisperKit",
                "OpenCastTranscription"
            ],
            // No `resources:` here on purpose: a test-target resource bundle
            // generates a test-local `Bundle.module` that shadows the main
            // module's and breaks the resource-bundle tests. Test fixtures
            // (Fixtures/) load via #filePath instead.
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ],
    swiftLanguageModes: [.v5, .v6]
)

func vendoredArgmaxSwiftSettings() -> [SwiftSetting] {
    [
        .swiftLanguageMode(.v5),
        .enableExperimentalFeature("StrictConcurrency")
    ]
}
