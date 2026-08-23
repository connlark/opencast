// swift-tools-version: 6.3

import PackageDescription

let swift63Settings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "OpenCastCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "OpenCastCore", targets: ["OpenCastCore"])
    ],
    targets: [
        .target(
            name: "OpenCastDateParsing",
            exclude: [
                "LICENSE-curl.txt",
                "UPSTREAM.md"
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "OpenCastCore",
            dependencies: ["OpenCastDateParsing"],
            swiftSettings: swift63Settings
        ),
        .testTarget(
            name: "OpenCastCoreTests",
            dependencies: ["OpenCastCore"],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: swift63Settings
        )
    ],
    swiftLanguageModes: [.v6]
)
