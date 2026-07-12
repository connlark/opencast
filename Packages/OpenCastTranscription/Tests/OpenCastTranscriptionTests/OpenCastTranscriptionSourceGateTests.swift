import Foundation
import Testing

@Suite("OpenCast transcription source gates")
struct OpenCastTranscriptionSourceGateTests {
    @Test("Vendored runtime has no compiled session API references")
    func vendoredRuntimeHasNoSessionAPIReferences() throws {
        let sources = try allVendoredSources()
        let sourceText = sources.map(\.text).joined(separator: "\n")

        #expect(!sources.isEmpty)
        #expect(!sourceText.isEmpty)
        #expect(sources.contains { $0.url.path.hasSuffix("Sources/WhisperKit/Core/WhisperKit.swift") })

        for deniedReference in [
            "URLSession",
            "URLRequest",
            "dataTask",
            "URLSession.shared",
            "NSURLSession",
            "import Network",
            "NWConnection"
        ] {
            #expect(!sourceText.contains(deniedReference), "Unexpected network API reference: \(deniedReference)")
        }
    }

    @Test("Remote entry points are explicitly unavailable")
    func remoteEntryPointsAreUnavailable() throws {
        let packageRoot = packageRoot()
        let entryPoints: [(file: String, declaration: String)] = [
            (
                file: "Sources/WhisperKit/Core/WhisperKit.swift",
                declaration: "public static func recommendedRemoteModels("
            ),
            (
                file: "Sources/WhisperKit/Core/WhisperKit.swift",
                declaration: "public static func fetchModelSupportConfig("
            ),
            (
                file: "Sources/WhisperKit/Core/WhisperKit.swift",
                declaration: "public static func fetchAvailableModels("
            ),
            (
                file: "Sources/WhisperKit/Core/WhisperKit.swift",
                declaration: "public static func download("
            ),
            (
                file: "Sources/ArgmaxCore/HubWrapper.swift",
                declaration: "public func snapshot("
            ),
            (
                file: "Sources/ArgmaxCore/HubWrapper.swift",
                declaration: "public func getFilenames("
            ),
            (
                file: "Sources/ArgmaxCore/External/Hub/HubApi.swift",
                declaration: "func snapshot("
            ),
            (
                file: "Sources/ArgmaxCore/External/Hub/HubApi.swift",
                declaration: "func getFilenames("
            ),
            (
                file: "Sources/ArgmaxCore/AutoTokenizerWrapper.swift",
                declaration: "public static func from(\n        pretrained model: String"
            ),
            (
                file: "Sources/ArgmaxCore/External/Hub/Hub.swift",
                declaration: "init(\n        modelName: String"
            )
        ]

        for entryPoint in entryPoints {
            let source = try String(
                contentsOf: packageRoot.appending(path: entryPoint.file),
                encoding: .utf8
            )
            assertUnavailableDeclaration(entryPoint.declaration, in: source, file: entryPoint.file)
        }
    }

    private func allVendoredSources() throws -> [(url: URL, text: String)] {
        let sourceRoots = [
            packageRoot().appending(path: "Sources/ArgmaxCore"),
            packageRoot().appending(path: "Sources/WhisperKit")
        ]
        var sources: [(url: URL, text: String)] = []

        for root in sourceRoots {
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                sources.append((url, text))
            }
        }

        return sources
    }

    private func assertUnavailableDeclaration(_ declaration: String, in source: String, file: String) {
        guard let range = source.range(of: declaration) else {
            Issue.record("Missing remote entry point declaration \(declaration) in \(file)")
            return
        }

        let prefix = source[..<range.lowerBound].suffix(500)
        #expect(
            prefix.contains("@available(*, unavailable"),
            "Remote entry point \(declaration) in \(file) is not marked unavailable near its declaration"
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
