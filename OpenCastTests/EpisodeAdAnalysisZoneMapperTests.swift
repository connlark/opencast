import Foundation
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad analysis zone mapper")
struct EpisodeAdAnalysisZoneMapperTests {
    @Test
    func sortsClampsDropsInvalidAndMergesKindAgnosticGaps() {
        let document = makeDocument(spans: [
            span(id: 4, kind: .insertedAd, start: 25.5, end: 45),
            span(id: 2, kind: .houseOrNetworkPromo, start: 5.8, end: 7),
            span(id: 5, kind: .hostReadAd, start: 12, end: 12),
            span(id: 1, kind: .hostReadAd, start: -5, end: 5),
            span(id: 6, kind: .insertedAd, start: .nan, end: 18),
            span(id: 3, kind: .hostReadAd, start: 20, end: 25)
        ])

        let zones = EpisodeAdAnalysisZoneMapper.zones(for: document, duration: 30)

        #expect(zones == [
            PlaybackSkipZone(id: 1, startTime: 0, endTime: 7),
            PlaybackSkipZone(id: 3, startTime: 20, endTime: 30)
        ])
    }

    @Test
    func gapsGreaterThanOneSecondRemainSeparate() {
        let document = makeDocument(spans: [
            span(id: 1, kind: .hostReadAd, start: 10, end: 12),
            span(id: 2, kind: .insertedAd, start: 13.2, end: 16)
        ])

        let zones = EpisodeAdAnalysisZoneMapper.zones(for: document, duration: 60)

        #expect(zones == [
            PlaybackSkipZone(id: 1, startTime: 10, endTime: 12),
            PlaybackSkipZone(id: 2, startTime: 13.2, endTime: 16)
        ])
    }

    @Test
    func confidenceFloorSplitsTiersExactlyAtPointEight() {
        let document = makeDocument(spans: [
            span(id: 1, kind: .hostReadAd, start: 10, end: 20, confidence: 0.80),
            span(id: 2, kind: .insertedAd, start: 30, end: 40, confidence: 0.79),
            span(id: 3, kind: .hostReadAd, start: 50, end: 60, confidence: 1.0),
            span(id: 4, kind: .insertedAd, start: 70, end: 80, confidence: 0.0)
        ])

        let tiers = EpisodeAdAnalysisZoneMapper.zoneTiers(for: document, duration: 100)

        #expect(tiers.autoSkip == [
            PlaybackSkipZone(id: 1, startTime: 10, endTime: 20),
            PlaybackSkipZone(id: 3, startTime: 50, endTime: 60)
        ])
        #expect(tiers.displayOnly == [
            PlaybackSkipZone(id: 2, startTime: 30, endTime: 40),
            PlaybackSkipZone(id: 4, startTime: 70, endTime: 80)
        ])
    }

    @Test
    func tiersMergeInternallyButDisplayOnlyNeverExtendsAutoSkip() {
        // An adjacent (gap <= 1s) low-confidence span must not stretch the
        // auto-skip zone; each tier merges only with itself.
        let document = makeDocument(spans: [
            span(id: 1, kind: .hostReadAd, start: 10, end: 20, confidence: 0.9),
            span(id: 2, kind: .insertedAd, start: 20.5, end: 30, confidence: 0.5),
            span(id: 3, kind: .insertedAd, start: 30.5, end: 40, confidence: 0.6),
            span(id: 4, kind: .hostReadAd, start: 40.5, end: 50, confidence: 0.95)
        ])

        let tiers = EpisodeAdAnalysisZoneMapper.zoneTiers(for: document, duration: 100)

        #expect(tiers.autoSkip == [
            PlaybackSkipZone(id: 1, startTime: 10, endTime: 20),
            PlaybackSkipZone(id: 4, startTime: 40.5, endTime: 50)
        ])
        #expect(tiers.displayOnly == [
            PlaybackSkipZone(id: 2, startTime: 20.5, endTime: 40)
        ])
    }

    @Test
    func missingDurationKeepsFiniteTimelineBounds() {
        let document = makeDocument(spans: [
            span(id: 1, kind: .hostReadAd, start: 30, end: 75)
        ])

        let zones = EpisodeAdAnalysisZoneMapper.zones(for: document, duration: nil)

        #expect(zones == [
            PlaybackSkipZone(id: 1, startTime: 30, endTime: 75)
        ])
    }

    @Test
    func appModelPushesFreshZonesAndClearsStaleOrDeletedAnalysis() async throws {
        let fixture = try makeAppModelFixture()
        let context = fixture.context
        let transcriptFileStore = fixture.transcriptFileStore
        let adAnalysisFileStore = fixture.adAnalysisFileStore
        let playback = fixture.playback
        let appModel = fixture.appModel
        let transcript = makeTranscriptDocument()
        let seeded = try seedCompletedAnalysis(
            transcript: transcript,
            spans: [
                span(id: 1, kind: .hostReadAd, start: 4, end: 9),
                span(id: 2, kind: .insertedAd, start: 12, end: 18, confidence: 0.5)
            ],
            in: fixture
        )
        let analysis = seeded.analysis
        let analysisRelativePath = seeded.analysisRelativePath
        let transcriptRelativePath = seeded.transcriptRelativePath

        appModel.loadLocalTranscriptionState(modelContext: context)
        try playback.load(makeEpisode(duration: 30), startPosition: 0)
        appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        await appModel.waitForSkipZoneRefresh()
        // Only the >= 0.8 tier reaches the playback policy; the 0.5 span is
        // display-only.
        #expect(playback.skipZones == [
            PlaybackSkipZone(id: 1, startTime: 4, endTime: 9)
        ])
        #expect(appModel.displayOnlySkipZones == [
            PlaybackSkipZone(id: 2, startTime: 12, endTime: 18)
        ])

        let staleTranscript = makeTranscriptDocument(updatedAt: transcript.updatedAt.addingTimeInterval(5))
        try transcriptFileStore.write(staleTranscript, relativePath: transcriptRelativePath)
        appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        await appModel.waitForSkipZoneRefresh()
        #expect(playback.skipZones == [])
        #expect(appModel.displayOnlySkipZones == [])

        try transcriptFileStore.write(transcript, relativePath: transcriptRelativePath)
        appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        await appModel.waitForSkipZoneRefresh()
        #expect(playback.skipZones == [
            PlaybackSkipZone(id: 1, startTime: 4, endTime: 9)
        ])

        // A pre-step-4 ads_only document is outdated even with current
        // transcript inputs: zero zones in either tier.
        var outdatedPolicyAnalysis = analysis
        outdatedPolicyAnalysis.policy = "ads_only"
        try adAnalysisFileStore.write(outdatedPolicyAnalysis, relativePath: analysisRelativePath)
        appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        await appModel.waitForSkipZoneRefresh()
        #expect(playback.skipZones == [])
        #expect(appModel.displayOnlySkipZones == [])

        try adAnalysisFileStore.write(analysis, relativePath: analysisRelativePath)
        appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        await appModel.waitForSkipZoneRefresh()
        #expect(playback.skipZones == [
            PlaybackSkipZone(id: 1, startTime: 4, endTime: 9)
        ])

        appModel.deleteEpisodeAdAnalysis(episodeID: transcript.episodeID, modelContext: context)
        await appModel.waitForSkipZoneRefresh()
        #expect(playback.skipZones == [])
        #expect(appModel.displayOnlySkipZones == [])
    }

    @Test
    func zonesInstallAsynchronouslyAfterPlaybackStarts() async throws {
        let fixture = try makeAppModelFixture()
        let transcript = makeTranscriptDocument()
        try seedCompletedAnalysis(
            transcript: transcript,
            spans: [span(id: 1, kind: .hostReadAd, start: 4, end: 9)],
            in: fixture
        )

        fixture.appModel.loadLocalTranscriptionState(modelContext: fixture.context)
        await fixture.appModel.waitForSkipZoneRefresh()
        try fixture.playback.load(makeEpisode(duration: 30), startPosition: 0)
        fixture.appModel.refreshPlaybackSkipZonesForCurrentEpisode()

        // The decode runs off-main: nothing is installed at the call boundary,
        // zones attach when the load completes.
        #expect(fixture.playback.skipZones == [])
        #expect(fixture.appModel.displayOnlySkipZones == [])
        await fixture.appModel.waitForSkipZoneRefresh()
        #expect(fixture.playback.skipZones == [
            PlaybackSkipZone(id: 1, startTime: 4, endTime: 9)
        ])
    }

    @Test
    func staleZoneResultForSwitchedAwayEpisodeDoesNotInstall() async throws {
        let fixture = try makeAppModelFixture()
        let transcript = makeTranscriptDocument()
        try seedCompletedAnalysis(
            transcript: transcript,
            spans: [span(id: 1, kind: .hostReadAd, start: 4, end: 9)],
            in: fixture
        )

        fixture.appModel.loadLocalTranscriptionState(modelContext: fixture.context)
        await fixture.appModel.waitForSkipZoneRefresh()
        try fixture.playback.load(makeEpisode(duration: 30), startPosition: 0)
        fixture.appModel.refreshPlaybackSkipZonesForCurrentEpisode()

        // Switch episodes while the analyzed episode's zone load is in flight;
        // its result must not attach to the new episode.
        try fixture.playback.load(makeOtherEpisode(duration: 45), startPosition: 0)
        await fixture.appModel.waitForSkipZoneRefresh()
        #expect(fixture.playback.skipZones == [])
        #expect(fixture.appModel.displayOnlySkipZones == [])
    }

    @Test
    func synchronousOutroCompletionPreservesAdvancedEpisodeZones() async throws {
        let fixture = try makeAppModelFixture()
        let transcript = makeTranscriptDocument()
        try seedCompletedAnalysis(
            transcript: transcript,
            spans: [
                span(id: 1, kind: .hostReadAd, start: 40, end: 55),
                span(id: 2, kind: .insertedAd, start: 10, end: 20, confidence: 0.5)
            ],
            in: fixture
        )
        fixture.appModel.loadLocalTranscriptionState(modelContext: fixture.context)
        await fixture.appModel.waitForSkipZoneRefresh()

        var didCompleteFirstEpisode = false
        fixture.playback.setEpisodeFinishedHandler { _, _ in
            didCompleteFirstEpisode = true
            try? fixture.playback.load(makeOtherEpisode(duration: 45))
            fixture.appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        }
        try fixture.playback.load(
            makeEpisode(duration: 60),
            startPosition: 45,
            boundaries: PlaybackEpisodeBoundaries(skipOutroSeconds: 10)
        )

        fixture.appModel.refreshPlaybackSkipZonesForCurrentEpisode()
        await fixture.appModel.waitForSkipZoneRefresh()

        #expect(didCompleteFirstEpisode)
        #expect(fixture.playback.currentEpisode?.id.rawValue == "other-episode")
        #expect(fixture.playback.skipZones == [])
        #expect(fixture.appModel.displayOnlySkipZones == [])
    }

    private struct AppModelFixture {
        let context: ModelContext
        let transcriptFileStore: EpisodeTranscriptFileStore
        let adAnalysisFileStore: EpisodeAdAnalysisFileStore
        let playback: AVFoundationPlaybackController
        let appModel: OpenCastAppModel
    }

    private func makeAppModelFixture() throws -> AppModelFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let adAnalyses = EpisodeAdAnalysisStore(
            client: UnusedEpisodeAdAnalysisClient(),
            fileStore: adAnalysisFileStore
        )
        let playback = AVFoundationPlaybackController()
        let appModel = OpenCastAppModel(
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            playback: playback,
            allowsAutomaticFeedRefresh: false
        )
        return AppModelFixture(
            context: context,
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            playback: playback,
            appModel: appModel
        )
    }

    @discardableResult
    private func seedCompletedAnalysis(
        transcript: EpisodeTranscriptDocument,
        spans: [EpisodeAdAnalysisSpan],
        in fixture: AppModelFixture
    ) throws -> (
        analysis: EpisodeAdAnalysisDocument,
        analysisRelativePath: String,
        transcriptRelativePath: String
    ) {
        let transcriptRelativePath = fixture.transcriptFileStore.relativePath(
            episodeID: transcript.episodeID,
            fingerprint: "transcript"
        )
        try fixture.transcriptFileStore.write(transcript, relativePath: transcriptRelativePath)
        fixture.context.insert(EpisodeTranscriptRecord(
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
            transcriptRelativePath: transcriptRelativePath,
            createdAt: transcript.createdAt,
            updatedAt: transcript.updatedAt
        ))

        let fingerprint = fixture.adAnalysisFileStore.transcriptFingerprint(for: transcript)
        let analysis = makeDocument(
            transcript: transcript,
            fingerprint: fingerprint,
            spans: spans
        )
        let analysisRelativePath = fixture.adAnalysisFileStore.relativePath(
            episodeID: transcript.episodeID,
            transcriptFingerprint: fingerprint
        )
        try fixture.adAnalysisFileStore.write(analysis, relativePath: analysisRelativePath)
        fixture.context.insert(EpisodeAdAnalysisRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: transcript.segments.count,
            transcriptState: .completed,
            state: .completed,
            analysisRelativePath: analysisRelativePath,
            model: analysis.model,
            policy: analysis.policy,
            spanCount: analysis.spans.count,
            warningCount: 0,
            createdAt: analysis.createdAt,
            updatedAt: analysis.updatedAt
        ))
        try fixture.context.save()
        return (analysis, analysisRelativePath, transcriptRelativePath)
    }

    private func makeDocument(spans: [EpisodeAdAnalysisSpan]) -> EpisodeAdAnalysisDocument {
        EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: "episode",
            podcastID: "podcast",
            requestID: "request",
            transcriptFingerprint: "fingerprint",
            transcriptUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            transcriptSegmentCount: 1,
            model: "gemini-test",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: spans,
            warnings: [],
            usage: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_002)
        )
    }

    private func makeDocument(
        transcript: EpisodeTranscriptDocument,
        fingerprint: String,
        spans: [EpisodeAdAnalysisSpan]
    ) -> EpisodeAdAnalysisDocument {
        EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            requestID: "request",
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: transcript.segments.count,
            model: "gemini-test",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: spans,
            warnings: [],
            usage: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_002)
        )
    }

    private func makeTranscriptDocument(
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> EpisodeTranscriptDocument {
        let segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 4,
                text: "Welcome back.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 4,
                end: 9,
                text: "This episode is brought to you by Example.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]

        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "episode",
            podcastID: "podcast",
            sourceAudioURL: "https://example.com/episode.mp3",
            sourceFileByteCount: 123,
            sourceFileSHA256: "source",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 30,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    private func makeEpisode(duration: TimeInterval) -> Episode {
        Episode(
            id: EpisodeID(rawValue: "episode"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Episode",
            duration: duration,
            audioURL: URL(filePath: "/tmp/opencast-zone-mapper-test.m4a")
        )
    }

    private func makeOtherEpisode(duration: TimeInterval) -> Episode {
        Episode(
            id: EpisodeID(rawValue: "other-episode"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Other Episode",
            duration: duration,
            audioURL: URL(filePath: "/tmp/opencast-zone-mapper-test-other.m4a")
        )
    }

    private func span(
        id: Int,
        kind: EpisodeAdAnalysisSpanKind,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double = 0.9
    ) -> EpisodeAdAnalysisSpan {
        EpisodeAdAnalysisSpan(
            id: id,
            kind: kind,
            label: "Span \(id)",
            startSegmentID: id,
            endSegmentID: id,
            startTime: start,
            endTime: end,
            confidence: confidence,
            evidenceQuote: "example"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastZoneMapperTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct UnusedEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }
}
