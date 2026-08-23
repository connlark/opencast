// swift-tools-version: 6.3

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
            swiftSettings: swift63Settings()
        ),
        .target(
            name: "WhisperKit",
            dependencies: ["ArgmaxCore"],
            swiftSettings: swift63Settings()
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
            swiftSettings: swift63Settings()
        ),
        .executableTarget(
            name: "OpenCastTranscriptionExport",
            dependencies: ["OpenCastTranscription"],
            swiftSettings: swift63Settings()
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
            swiftSettings: swift63Settings()
        )
    ],
    swiftLanguageModes: [.v6]
)

func swift63Settings() -> [SwiftSetting] {
    [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault")
    ]
}
