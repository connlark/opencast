import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcript improvement", .serialized)
struct EpisodeTranscriptImprovementCoordinatorTests {
    @Test("Improve completes with an Apple Speech transcript")
    func improveCompletesWithAppleSpeechTranscript() async throws {
        let harness = try await makeHarness { request in
            completedStream(for: request)
        }

        harness.coordinator.start(
            episode: harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.localFileURL,
            podcastLanguageCode: nil,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.phase == .completed })
        let record = try #require(harness.transcriptions.record(for: harness.episode.episodeID))
        #expect(record.state == .completed)
        #expect(record.modelIdentifier != harness.priorModelIdentifier)
        #expect(harness.transcriptions.document(for: harness.episode.episodeID)?.modelIdentifier == record.modelIdentifier)
        #expect(harness.transcriber.requests.map(\.engine) == [.whisper, .appleSpeech])
    }

    @Test("Backgrounding interrupt restores Whisper and reports interrupted")
    func backgroundingInterruptRestoresWhisperAndReportsInterrupted() async throws {
        let harness = try await makeHarness { _ in
            hangingStream()
        }

        harness.coordinator.start(
            episode: harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.localFileURL,
            podcastLanguageCode: nil,
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.transcriber.requests.count == 2 })

        harness.transcriptions.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil { harness.coordinator.phase == .interrupted })
        let record = try #require(harness.transcriptions.record(for: harness.episode.episodeID))
        #expect(record.state == .completed)
        #expect(record.modelIdentifier == harness.priorModelIdentifier)
        #expect(harness.transcriptions.document(for: harness.episode.episodeID) != nil)

        harness.coordinator.acknowledgeTerminal()
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.episodeID == nil)
    }

    @Test("Cancel keeps the current transcript and returns to idle")
    func cancelKeepsCurrentTranscriptAndReturnsToIdle() async throws {
        let harness = try await makeHarness { _ in
            hangingStream()
        }

        harness.coordinator.start(
            episode: harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.localFileURL,
            podcastLanguageCode: nil,
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.transcriber.requests.count == 2 })

        harness.coordinator.cancel(modelContext: harness.context)

        #expect(harness.coordinator.phase == .idle)
        #expect(await waitUntil {
            harness.transcriptions.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.transcriptions.hasActiveJob
        })
        let record = try #require(harness.transcriptions.record(for: harness.episode.episodeID))
        #expect(record.modelIdentifier == harness.priorModelIdentifier)
    }

    @Test("A failed improve restores Whisper and surfaces the failure")
    func failedImproveRestoresWhisperAndSurfacesFailure() async throws {
        let harness = try await makeHarness { _ in
            failingStream(message: "Deterministic improve failure")
        }

        harness.coordinator.start(
            episode: harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.localFileURL,
            podcastLanguageCode: nil,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.phase == .failed("Deterministic improve failure") })
        let record = try #require(harness.transcriptions.record(for: harness.episode.episodeID))
        #expect(record.state == .completed)
        #expect(record.modelIdentifier == harness.priorModelIdentifier)
    }

    @Test("Improve does not start while another transcription job is active")
    func improveDoesNotStartWhileAnotherJobIsActive() async throws {
        let harness = try await makeHarness { _ in
            hangingStream()
        }
        harness.transcriptions.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.localFileURL,
            engine: .whisper,
            modelIdentity: EpisodeTranscriptionModelIdentity(
                modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
                version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
                treeSHA256: String(repeating: "b", count: 64)
            ),
            languageCode: "en",
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.transcriptions.hasActiveJob })

        harness.coordinator.start(
            episode: harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.localFileURL,
            podcastLanguageCode: nil,
            modelContext: harness.context
        )

        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.episodeID == nil)

        harness.transcriptions.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )
        #expect(await waitUntil { !harness.transcriptions.hasActiveJob })
    }

    /// Builds a completed Whisper transcript, then hands back a coordinator
    /// whose improve attempt streams are test-driven.
    private func makeHarness(
        improveStream: @escaping @MainActor (EpisodeTranscriptionRunRequest) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>
    ) async throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        transcriptions: EpisodeTranscriptionStore,
        transcriber: EpisodeTranscriptionRequestTestTranscriber,
        coordinator: EpisodeTranscriptImprovementCoordinator,
        priorModelIdentifier: String
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastImprovementTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let episode = makeEpisode(episodeID: UUID().uuidString)
        let localFileURL = directory.appending(path: "\(episode.episodeID).mp3")
        try Data("deterministic improvement audio".utf8).write(to: localFileURL, options: .atomic)
        let downloadRecord = EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            localRelativePath: "EpisodeDownloads/\(episode.episodeID).mp3",
            state: .completed,
            bytesReceived: 10,
            bytesExpected: 10
        )
        context.insert(downloadRecord)
        try context.save()

        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, attempt in
            attempt == 1
                ? completedStream(for: request)
                : improveStream(request)
        }
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: directory),
            failureEnvironment: { .foreground }
        )
        transcriptions.startTranscription(
            episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            engine: .whisper,
            modelIdentity: EpisodeTranscriptionModelIdentity(
                modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
                version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
                treeSHA256: String(repeating: "b", count: 64)
            ),
            languageCode: "en",
            modelContext: context
        )
        _ = await waitUntil {
            transcriptions.record(for: episode.episodeID)?.state == .completed
                && !transcriptions.hasActiveJob
        }
        guard let priorRecord = transcriptions.record(for: episode.episodeID),
              priorRecord.state == .completed
        else {
            throw ImprovementHarnessError.priorTranscriptNeverCompleted
        }

        let coordinator = EpisodeTranscriptImprovementCoordinator(
            appleSpeechAssets: AppleSpeechAssetStore(provider: FakeAppleSpeechAssetProvider()),
            transcriptions: transcriptions
        )
        return (
            context,
            episode,
            downloadRecord,
            localFileURL,
            transcriptions,
            transcriber,
            coordinator,
            priorRecord.modelIdentifier
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private enum ImprovementHarnessError: Error {
    case priorTranscriptNeverCompleted
}

private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
    EpisodeListItemSnapshot(
        episodeID: episodeID,
        podcastID: "https://example.com/feed.xml",
        podcastTitle: "Example Show",
        title: "Improvement Episode",
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

@MainActor
private func completedStream(
    for request: EpisodeTranscriptionRunRequest
) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 2,
            text: "Deterministic transcript",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        continuation.yield(.finished(OpenCastTranscriptionResult(
            modelIdentifier: request.modelIdentifier,
            languageCode: request.languageCode,
            text: segment.text,
            segments: [segment],
            timings: OpenCastTranscriptionTimings(
                audioDuration: 60,
                modelLoading: 0,
                audioLoading: 0,
                transcription: 1,
                fullPipeline: 1,
                realTimeFactor: 0.02,
                decodingFallbackCount: 0,
                decodingFallback: 0,
                decodingWindowCount: 1
            )
        )))
        continuation.finish()
    }
}

private func hangingStream() -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.progress(EpisodeTranscriptionProgress(
            audioDuration: 60,
            completedDuration: 1,
            checkpointCount: 0,
            currentWindowIndex: 0,
            currentText: nil
        )))
    }
}

private func failingStream(
    message: String
) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: NSError(
            domain: "EpisodeTranscriptImprovementCoordinatorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
