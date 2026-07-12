// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenCastCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v12)
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
            dependencies: ["OpenCastDateParsing"]
        ),
        .testTarget(
            name: "OpenCastCoreTests",
            dependencies: ["OpenCastCore"],
            resources: [
                .process("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
