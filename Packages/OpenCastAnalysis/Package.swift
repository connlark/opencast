// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "OpenCastAnalysis",
    platforms: [
        .iOS(.v27),
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenCastAnalysis", targets: ["OpenCastAnalysis"]),
        .library(name: "OpenCastAnalysisProviders", targets: ["OpenCastAnalysisProviders"]),
        .executable(name: "OpenCastAnalysisReplay", targets: ["OpenCastAnalysisReplay"])
    ],
    targets: [
        .target(
            name: "OpenCastAnalysis",
            swiftSettings: swift63Settings()
        ),
        .target(
            name: "OpenCastAnalysisProviders",
            dependencies: ["OpenCastAnalysis"],
            swiftSettings: swift63Settings()
        ),
        .executableTarget(
            name: "OpenCastAnalysisReplay",
            dependencies: ["OpenCastAnalysis", "OpenCastAnalysisProviders"],
            swiftSettings: swift63Settings()
        ),
        .testTarget(
            name: "OpenCastAnalysisTests",
            dependencies: [
                "OpenCastAnalysis",
                "OpenCastAnalysisProviders",
                "OpenCastAnalysisReplay"
            ],
            // Fixtures load via #filePath, like OpenCastTranscription's, so no
            // test-local resource bundle is generated.
            exclude: ["Fixtures"],
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
