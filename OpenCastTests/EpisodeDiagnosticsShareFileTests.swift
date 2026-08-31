import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode diagnostics share file")
struct EpisodeDiagnosticsShareFileTests {
    @Test("Sanitized file name keeps readable text and drops unsafe characters")
    func sanitizedFileNameDropsUnsafeCharacters() {
        let name = EpisodeDiagnosticsShareFilePreparer.sanitizedFileName(
            podcastTitle: "My Show: Extras!/Weird",
            episodeTitle: "Ep #12 — \"Quotes\"",
            fileExtension: "mp3"
        )

        #expect(name == "My Show Extras Weird - Ep 12 Quotes.mp3")
    }

    @Test("Empty titles fall back to a generic episode stem")
    func emptyTitlesFallBackToGenericStem() {
        let name = EpisodeDiagnosticsShareFilePreparer.sanitizedFileName(
            podcastTitle: "///",
            episodeTitle: "!!!",
            fileExtension: "mp3"
        )

        #expect(name == "Episode.mp3")
    }

    @Test("Prepare hard-links the source and cleanup removes only the link")
    func prepareHardLinksAndCleanupRemovesOnlyLink() throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appending(path: "source.mp3")
        try Data("episode audio".utf8).write(to: source, options: .atomic)

        let shareFile = EpisodeDiagnosticsShareFilePreparer.prepare(
            source: source,
            podcastTitle: "UI Test Show",
            episodeTitle: "Deterministic UI Episode"
        )

        let temporaryDirectoryURL = try #require(shareFile.temporaryDirectoryURL)
        #expect(shareFile.url != source)
        #expect(shareFile.url.lastPathComponent == "UI Test Show - Deterministic UI Episode.mp3")
        #expect(try Data(contentsOf: shareFile.url) == Data("episode audio".utf8))

        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: shareFile.url.path)
        #expect(
            sourceAttributes[.systemFileNumber] as? Int == linkAttributes[.systemFileNumber] as? Int,
            "share file should be a hard link, not a copy"
        )

        EpisodeDiagnosticsShareFilePreparer.cleanUp(shareFile)

        #expect(!FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("An extensionless source shares as .audio, never claiming a format")
    func extensionlessSourceSharesAsAudio() throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appending(path: "source")
        try Data("episode audio".utf8).write(to: source, options: .atomic)

        let shareFile = EpisodeDiagnosticsShareFilePreparer.prepare(
            source: source,
            podcastTitle: "Show",
            episodeTitle: "Episode"
        )

        #expect(shareFile.url.lastPathComponent == "Show - Episode.audio")
        EpisodeDiagnosticsShareFilePreparer.cleanUp(shareFile)
    }

    @Test("Prepare falls back to the original URL when linking fails")
    func prepareFallsBackWhenLinkingFails() throws {
        let missingSource = FileManager.default.temporaryDirectory
            .appending(path: "missing-\(UUID().uuidString).mp3")

        let shareFile = EpisodeDiagnosticsShareFilePreparer.prepare(
            source: missingSource,
            podcastTitle: "Show",
            episodeTitle: "Episode"
        )

        #expect(shareFile.url == missingSource)
        #expect(shareFile.temporaryDirectoryURL == nil)
        EpisodeDiagnosticsShareFilePreparer.cleanUp(shareFile)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastDiagnosticsShareTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
