import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("PlaybackChaptersCoordinator", .serialized)
struct PlaybackChaptersCoordinatorTests {
    @Test("Chapters follow the player item: a source switch and an unload clear the list")
    func followsPlayerItem() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let model = fixture.model
        let episode = Episode(
            id: EpisodeID(rawValue: "chaptered"),
            podcastID: PodcastID(rawValue: OpenCastSystemActionFixture.feed),
            podcastTitle: "A Show",
            title: "Chaptered",
            duration: 3,
            audioURL: Self.fixture("ChapteredSilence.mp3")
        )
        try model.playback.load(episode)
        model.refreshPlaybackSkipZonesForCurrentEpisode()
        #expect(await waitUntil { model.currentEpisodeChapters.chapters.count == 3 })
        #expect(model.currentEpisodeChapters.source == .embedded)

        // The controller rebuilds its item on its own for a download switch
        // (and for a failed-item recovery); no app-model refresh follows.
        #expect(model.playback.useDownloadedAudio(at: Self.fixture("UntaggedSilence.mp3"), for: episode.id))
        #expect(await waitUntil { model.currentEpisodeChapters.isEmpty })
        // The clear above is immediate; the untagged file's read must settle
        // empty too, so a late read of the old item cannot repopulate it.
        await model.waitForChapterRefresh()
        #expect(model.currentEpisodeChapters.isEmpty)

        try model.playback.load(episode)
        #expect(await waitUntil { model.currentEpisodeChapters.chapters.count == 3 })

        model.playback.unload()
        #expect(await waitUntil { model.currentEpisodeChapters.isEmpty })
    }

    @Test("A declared chapters document serves the playing episode's chapters")
    func declaredDocumentServesPublisherChapters() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.publisherDocument)])
        let model = try await OpenCastSystemActionFixture.make(httpClient: client).model
        let episode = try await Self.cacheDeclaredEpisode(in: model)

        try model.playback.load(episode)
        model.refreshPlaybackSkipZonesForCurrentEpisode()

        #expect(await waitUntil { model.currentEpisodeChapters.chapters.count == 2 })
        #expect(model.currentEpisodeChapters.source == .publisher)
        #expect(model.currentEpisodeChapters.chapters.map(\.title) == ["Opening", "Interview"])
        #expect(client.requests.map(\.url?.absoluteString) == [Self.documentURL])
    }

    @Test("A declared document that cannot be read keeps generated chapters out")
    func unreadableDocumentKeepsListEmpty() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Data(), statusCode: 404)])
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let model = try await Self.settleDeclaredEpisode(client: client, context: context)

        #expect(model.currentEpisodeChapters.isEmpty)
        #expect(client.requestCount == 1)
        #expect(await !model.publisherChapters.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.documentURL))
    }

    @Test("A declared document with nothing usable leaves the slot to generated chapters")
    func emptyDocumentFallsThrough() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Data(#"{"version":"1.2.0","chapters":[]}"#.utf8))])
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let model = try await Self.settleDeclaredEpisode(client: client, context: context)

        #expect(model.currentEpisodeChapters.source == .generated(transcriptSourceSHA256: Self.transcriptSourceSHA256))
        #expect(model.currentEpisodeChapters.chapters.map(\.title) == ["Welcome", "The Sponsor Read"])
        #expect(client.requestCount == 1)
        #expect(await model.publisherChapters.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.documentURL))
    }

    @Test("A document whose declaration moved while it was fetched is not installed")
    func documentForMovedDeclarationIsNotInstalled() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.publisherDocument)])
        await client.hold()
        let model = try await OpenCastSystemActionFixture.make(httpClient: client).model
        let episode = try await Self.cacheDeclaredEpisode(in: model)
        try model.playback.load(episode)
        model.refreshPlaybackSkipZonesForCurrentEpisode()
        #expect(await waitUntil { client.requestCount == 1 })

        try await Self.cacheDeclaredEpisode(in: model, documentURL: Self.movedDocumentURL)
        await client.release()
        await model.publisherChapters.waitForFetch(episodeID: Self.episodeID)
        await model.waitForChapterRefresh()

        #expect(model.currentEpisodeChapters.isEmpty)
        #expect(client.requests.map(\.url?.absoluteString) == [Self.documentURL])
    }

    private static let chapteredFeedURL = "https://example.com/publisher-chaptered.xml"
    private static let episodeID = "publisher-chaptered"
    private static let documentURL = "https://example.com/chapters/publisher-chaptered.json"
    private static let movedDocumentURL = "https://example.com/chapters/publisher-chaptered-v2.json"
    private static let transcriptSourceSHA256 = "publisher-chaptered-source"
    private static let publisherDocument = Data(
        #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Opening"},{"startTime":1.5,"title":"Interview"}]}"#.utf8
    )

    /// Plays the declared episode, which also has a current generated
    /// analysis, and waits out its document fetch and every chapter refresh
    /// the load started; then one more refresh, awaited, so the list read
    /// next is one no later refresh replaces.
    private static func settleDeclaredEpisode(
        client: StubOpenCastHTTPClient,
        context: ModelContext
    ) async throws -> OpenCastAppModel {
        let model = try await makeModelWithGeneratedChapters(client: client, context: context)
        try model.playback.load(declaredEpisode())
        model.refreshPlaybackSkipZonesForCurrentEpisode()
        #expect(await waitUntil { client.requestCount == 1 })
        await model.publisherChapters.waitForFetch(episodeID: episodeID)
        await model.waitForChapterRefresh()
        model.refreshPlaybackSkipZonesForCurrentEpisode()
        await model.waitForChapterRefresh()
        return model
    }

    /// The declared episode with a current generated analysis written
    /// through the real stores: a completed transcript and its record, then
    /// an analysis run whose producer answers two chapters.
    private static func makeModelWithGeneratedChapters(
        client: StubOpenCastHTTPClient,
        context: ModelContext
    ) async throws -> OpenCastAppModel {
        let directory = URL.temporaryDirectory
            .appending(path: "PlaybackChaptersCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: ScriptedTranscriptAnalysisDrainClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: directory)
        )
        let model = OpenCastAppModel(
            httpClient: client,
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            analysisRuns: AnalysisRunRecordStore(directory: directory.appending(path: "AnalysisRuns")),
            allowsAutomaticFeedRefresh: false
        )
        let episode = try await cacheDeclaredEpisode(in: model)

        let transcript = completedTranscript(for: episode)
        let fingerprint = transcriptFileStore.fingerprint(
            sourceFileSHA256: transcript.sourceFileSHA256,
            modelIdentifier: transcript.modelIdentifier,
            modelVersion: transcript.modelVersion,
            modelTreeSHA256: transcript.modelTreeSHA256
        )
        let relativePath = transcriptFileStore.relativePath(episodeID: transcript.episodeID, fingerprint: fingerprint)
        try transcriptFileStore.write(transcript, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            sourceAudioURL: transcript.sourceAudioURL,
            sourceFileByteCount: transcript.sourceFileByteCount,
            sourceFileSHA256: transcript.sourceFileSHA256,
            modelIdentifier: transcript.modelIdentifier,
            modelVersion: transcript.modelVersion,
            modelTreeSHA256: transcript.modelTreeSHA256,
            languageCode: transcript.languageCode,
            state: .completed,
            audioDuration: transcript.audioDuration,
            completedDuration: transcript.audioDuration,
            checkpointCount: 0,
            transcriptRelativePath: relativePath,
            createdAt: transcript.createdAt,
            updatedAt: transcript.updatedAt
        ))
        try context.save()
        model.transcriptions.load(modelContext: context)

        let producer = FakeChaptersSummaryProducer()
        producer.attach(to: transcriptAnalyses)
        transcriptAnalyses.startAnalysis(
            transcript: transcript,
            episodeTitle: episode.title,
            podcastTitle: episode.podcastTitle,
            modelContext: context
        )
        #expect(await waitUntil { transcriptAnalyses.record(for: episodeID)?.state == .completed })
        let analysis = try await transcriptAnalyses.loadDocument(for: episodeID)
        let storedTranscript = try await model.transcriptions.loadDocument(for: episodeID)
        #expect(analysis.chapters.map(\.title) == ["Welcome", "The Sponsor Read"])
        #expect(await transcriptAnalyses.isCurrentAnalysisDocumentOffCaller(analysis, for: storedTranscript))
        return model
    }

    private static func completedTranscript(for episode: Episode) -> EpisodeTranscriptDocument {
        let segments = [
            OpenCastTranscriptSegment(id: 0, start: 0, end: 1, text: "Welcome back.", avgLogProbability: -0.1, noSpeechProbability: 0.01),
            OpenCastTranscriptSegment(
                id: 1,
                start: 1,
                end: 3,
                text: "This episode is brought to you by Example.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
        ]
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            sourceAudioURL: episode.audioURL?.absoluteString ?? "",
            sourceFileByteCount: 1_024,
            sourceFileSHA256: transcriptSourceSHA256,
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 3,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    /// Upserting again with another `documentURL` moves the declaration the
    /// way a feed refresh does.
    @discardableResult
    private static func cacheDeclaredEpisode(
        in model: OpenCastAppModel,
        documentURL: String = documentURL
    ) async throws -> Episode {
        let episode = declaredEpisode(documentURL: documentURL)
        try await model.library.localCache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(id: episode.podcastID, feedURL: URL(string: chapteredFeedURL)!, title: "A Show"),
                episodes: [episode]
            ),
            refreshedAt: .now
        )
        return episode
    }

    /// Untagged audio, so nothing embedded outranks the feed's document.
    private static func declaredEpisode(documentURL: String = documentURL) -> Episode {
        Episode(
            id: EpisodeID(rawValue: episodeID),
            podcastID: PodcastID(rawValue: chapteredFeedURL),
            podcastTitle: "A Show",
            title: "Publisher Chaptered",
            duration: 3,
            audioURL: fixture("UntaggedSilence.mp3"),
            chaptersURL: URL(string: documentURL)
        )
    }

    private static func fixture(_ name: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Packages/OpenCastPlayback/Tests/OpenCastPlaybackTests/Fixtures/\(name)")
    }
}
