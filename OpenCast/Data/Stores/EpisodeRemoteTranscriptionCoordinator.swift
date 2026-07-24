import Foundation
import Observation
import OpenCastTranscription
import SwiftData

/// Thin adapter for the plain Transcribe Remotely surface: owns the
/// observable request store and maps `RemoteTranscriptionJobRunner` events
/// and errors onto `RemoteTranscriptionRequestPhase`. The runner owns the
/// whole job (download, identity, upload fallback, poll, import, ack).
@Observable
final class EpisodeRemoteTranscriptionCoordinator {
    typealias UploadSessionFactory = RemoteTranscriptionJobRunner.UploadSessionFactory

    @ObservationIgnored private let runner: RemoteTranscriptionJobRunner
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    let store: RemoteTranscriptionJobStore

    init(
        api: any RemoteTranscriptionAPI,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        store: RemoteTranscriptionJobStore = RemoteTranscriptionJobStore(),
        uploadSessionFactory: UploadSessionFactory? = nil,
        transportRetryDelays: [Duration] = RemoteTranscriptionJobRunner.defaultTransportRetryDelays
    ) {
        self.store = store
        self.transcriptions = transcriptions
        runner = RemoteTranscriptionJobRunner(
            api: api,
            downloads: downloads,
            transcriptions: transcriptions,
            store: store,
            uploadSessionFactory: uploadSessionFactory,
            transportRetryDelays: transportRetryDelays
        )
    }

    func start(episode: EpisodeListItemSnapshot, modelContext: ModelContext) {
        guard !transcriptions.hasCompletedTranscript(for: episode.episodeID) else {
            return
        }
        guard !store.hasActiveRequest else {
            return
        }
        guard let audioURL = episode.audioURL, audioURL.isEmpty == false else {
            store.begin(episodeID: episode.episodeID, title: episode.title)
            store.finish(phase: .failed(.missingAudio))
            return
        }

        store.begin(episodeID: episode.episodeID, title: episode.title)
        store.activeTask = Task { [weak self] in
            await self?.run(episode: episode, enclosureURL: audioURL, modelContext: modelContext)
        }
    }

    func cancel() {
        store.cancelActiveRequest()
    }

    private func run(
        episode: EpisodeListItemSnapshot,
        enclosureURL: String,
        modelContext: ModelContext
    ) async {
        do {
            _ = try await runner.run(
                episode: episode,
                enclosureURL: enclosureURL,
                purpose: .transcription,
                modelContext: modelContext,
                onEvent: { [store] event in
                    store.update(phase: Self.phase(for: event))
                }
            )
            store.finish(phase: .completed)
        } catch is CancellationError {
            store.finish(phase: .cancelled)
        } catch let error as RemoteTranscriptionJobRunError {
            store.finish(phase: Self.terminalPhase(for: error))
        } catch {
            store.finish(phase: .failed(.serviceUnavailable))
        }
    }

    private static func phase(for event: RemoteTranscriptionJobEvent) -> RemoteTranscriptionRequestPhase {
        switch event {
        case .downloading, .queuedRemotely:
            .downloadingBoth
        case .verifying:
            .verifying
        case .waitingForCredits:
            .waitingForCredits
        case .processing(let progress):
            .processing(progress)
        case .detectingAds:
            // Plain transcription jobs never request the ad phase; keep the
            // last honest phase if a server ever reports it anyway.
            .saving
        case .uploadingExactCopy(let completed, let total):
            .uploadingExactCopy(completedParts: completed, totalParts: total)
        case .saving:
            .saving
        }
    }

    private static func terminalPhase(
        for error: RemoteTranscriptionJobRunError
    ) -> RemoteTranscriptionRequestPhase {
        switch error {
        case .mismatchLocalFallback:
            .mismatchLocalFallback
        case .remoteCancelled:
            .cancelled
        default:
            .failed(error.failureCategory)
        }
    }
}
