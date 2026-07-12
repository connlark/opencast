import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass auto resume")
struct AdFreePassAutoResumeTests {
    @Test("Foreground maintenance resumes environmental interruptions for the current episode")
    func foregroundMaintenanceResumesEnvironmentalInterruptions() async throws {
        let fixture = try makeFixture(
            episodeID: "auto-resume-environmental",
            errorMessage: EpisodeTranscriptionStore.environmentalInterruptMessage
        )

        fixture.appModel.resumeEnvironmentalAdFreePassIfNeeded(modelContext: fixture.context)

        #expect(await waitUntil {
            fixture.adAnalyses.record(for: fixture.episode.episodeID)?.state == .completed
        })
        #expect(fixture.transcriber.requestCount == 1)
        #expect(fixture.transcriber.lastRequest?.resumeStart == 2)
        #expect(fixture.scheduler.submitCallCount == 1)
    }

    @Test("Foreground maintenance does not resume plain user interruptions")
    func foregroundMaintenanceDoesNotResumePlainInterruptions() async throws {
        let fixture = try makeFixture(episodeID: "auto-resume-plain", errorMessage: nil)

        fixture.appModel.resumeEnvironmentalAdFreePassIfNeeded(modelContext: fixture.context)

        #expect(fixture.transcriber.requestCount == 0)
        #expect(fixture.scheduler.submitCallCount == 0)
        #expect(fixture.adAnalyses.record(for: fixture.episode.episodeID) == nil)
    }

    private func makeFixture(
        episodeID: String,
        errorMessage: String?
    ) throws -> AutoResumeFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let episode = makeEpisode(episodeID: episodeID)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloads = DownloadStore(fileStore: downloadFileStore)
        let modelInstaller = AutoResumeTranscriptionModelInstaller()
        let transcriptionModels = TranscriptionModelStore(installer: modelInstaller)
        let transcriber = AutoResumeCompletingTranscriber()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: transcriptFileStore
        )
        let adAnalyses = EpisodeAdAnalysisStore(
            client: AutoResumeAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let scheduler = AutoResumeBackgroundScheduler()
        let backgroundSession = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            adFreePassBackgroundSession: backgroundSession,
            allowsAutomaticFeedRefresh: false
        )

        let downloadRecord = try insertCompletedDownload(for: episode, fileStore: downloadFileStore, context: context)
        let localFileURL = downloadFileStore.fileURL(relativePath: try #require(downloadRecord.localRelativePath))
        try insertInterruptedTranscript(
            for: episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            modelSummary: modelInstaller.summary,
            fileStore: transcriptFileStore,
            context: context,
            errorMessage: errorMessage
        )
        downloads.load(modelContext: context)
        transcriptionModels.load(modelContext: context)
        transcriptions.load(modelContext: context)
        adAnalyses.load(modelContext: context)
        try appModel.playback.load(Episode(
            id: EpisodeID(rawValue: episode.episodeID),
            podcastID: PodcastID(rawValue: episode.podcastID),
            podcastTitle: episode.podcastTitle,
            title: episode.title,
            duration: episode.duration,
            audioURL: URL(string: episode.audioURL ?? "https://example.com/\(episodeID).mp3")
        ), startPosition: 0)

        return AutoResumeFixture(
            appModel: appModel,
            context: context,
            episode: episode,
            transcriber: transcriber,
            adAnalyses: adAnalyses,
            scheduler: scheduler
        )
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode",
            summary: nil,
            publishedAt: nil,
            duration: 60,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: episodeID,
            cachedAt: .now
        )
    }

    @discardableResult
    private func insertCompletedDownload(
        for episode: EpisodeListItemSnapshot,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws -> EpisodeDownloadRecord {
        let sourceURL = URL(string: episode.audioURL ?? "https://example.com/audio.mp3")!
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, sourceAudioURL: sourceURL)
        try fileStore.prepareDownloadsDirectory()
        let data = Data("downloaded \(episode.episodeID)".utf8)
        try data.write(to: fileStore.fileURL(relativePath: relativePath), options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        )
        context.insert(record)
        try context.save()
        return record
    }

    private func insertInterruptedTranscript(
        for episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        modelSummary: OpenCastWhisperModelInstalledSummary,
        fileStore: EpisodeTranscriptFileStore,
        context: ModelContext,
        errorMessage: String?
    ) throws {
        let data = try Data(contentsOf: localFileURL)
        let sourceSHA = OpenCastSHA256.hash(data)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, fingerprint: fingerprint)
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 2,
            text: "partial transcript",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        let document = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: downloadRecord.sourceAudioURL,
            sourceFileByteCount: Int64(data.count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [
                EpisodeTranscriptCheckpoint(id: 1, completedDuration: 2, segmentCount: 1, createdAt: .now)
            ],
            segments: [segment],
            text: segment.text,
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: downloadRecord.sourceAudioURL,
            sourceFileByteCount: Int64(data.count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            state: .interrupted,
            audioDuration: 60,
            completedDuration: 2,
            checkpointCount: 1,
            transcriptRelativePath: relativePath,
            errorMessage: errorMessage
        ))
        try context.save()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAdFreePassAutoResumeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<120 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

private struct AutoResumeFixture {
    let appModel: OpenCastAppModel
    let context: ModelContext
    let episode: EpisodeListItemSnapshot
    let transcriber: AutoResumeCompletingTranscriber
    let adAnalyses: EpisodeAdAnalysisStore
    let scheduler: AutoResumeBackgroundScheduler
}

private final class AutoResumeTranscriptionModelInstaller: TranscriptionModelInstalling, @unchecked Sendable {
    let summary = OpenCastWhisperModelInstalledSummary(
        modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
        version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
        totalByteCount: 10,
        treeSHA256: String(repeating: "d", count: 64)
    )

    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        summary
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(schemaVersion: 1, generatedAt: "2026-07-04T00:00:00Z", models: [])
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        summary
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
    }
}

private final class AutoResumeCompletingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0
    var lastRequest: EpisodeTranscriptionRunRequest?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        lastRequest = request
        return AsyncThrowingStream { continuation in
            let start = request.resumeStart ?? 0
            let segments = [
                OpenCastTranscriptSegment(
                    id: 0,
                    start: start,
                    end: start + 2,
                    text: "resumed transcript",
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                )
            ]
            continuation.yield(.finished(OpenCastTranscriptionResult(
                modelIdentifier: request.modelIdentifier,
                languageCode: request.languageCode,
                text: "resumed transcript",
                segments: segments,
                timings: OpenCastTranscriptionTimings(
                    audioDuration: 60,
                    modelLoading: 0.1,
                    audioLoading: 0.1,
                    transcription: 0.2,
                    fullPipeline: 0.4,
                    realTimeFactor: 0.01,
                    decodingFallbackCount: 0,
                    decodingFallback: 0,
                    decodingWindowCount: 1
                )
            )))
            continuation.finish()
        }
    }

    func unload() async {
    }
}

private final class AutoResumeAnalysisClient: EpisodeAdAnalysisClient, @unchecked Sendable {
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisAPIResponse {
        EpisodeAdAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "test",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [],
            warnings: [],
            usage: nil
        )
    }
}

private final class AutoResumeBackgroundScheduler: AdFreePassContinuedTaskScheduling {
    let supportsGPUResources = false
    private(set) var submitCallCount = 0
    private(set) var cancelledIdentifiers: [String] = []

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void
    ) -> Bool {
        true
    }

    func submit(identifier: String, title: String, subtitle: String, requiresGPU: Bool) throws {
        submitCallCount += 1
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }
}
