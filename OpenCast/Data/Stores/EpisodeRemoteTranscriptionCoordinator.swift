import Foundation
import Observation
import OpenCastTranscription
import SwiftData

/// Thin adapter for the plain Transcribe Remotely surface: owns the
/// observable request store and maps `RemoteTranscriptionJobRunner` events
/// and errors onto `RemoteTranscriptionRequestPhase`. The runner owns the
/// whole job (download, identity, upload fallback, poll, import, ack); this
/// coordinator owns the user's decisions about it: start, Resume/Try Again
/// (which re-attach the persisted reference), park, and the user cancel
/// that is the only path to `/cancel`.
@Observable
final class EpisodeRemoteTranscriptionCoordinator {
    typealias UploadSessionFactory = RemoteTranscriptionJobRunner.UploadSessionFactory

    enum StartOutcome: Equatable {
        case started
        case rejected(String)
    }

    @ObservationIgnored private let runner: RemoteTranscriptionJobRunner
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    /// Set by `park(exit:)` before the local task is cancelled, so the run's
    /// cancellation catch can tell a park from a user cancel.
    @ObservationIgnored private var pendingParkExit: RemoteTranscriptionJobExit?
    /// The in-flight user cancel, kept so a test or a later trigger can
    /// await its resolution. While it runs for an episode, further taps for
    /// that episode are no-ops: one tap burst sends at most one `/cancel`.
    @ObservationIgnored private(set) var userCancelTask: Task<Void, Never>?
    @ObservationIgnored private var userCancelEpisodeID: String?
    let store: RemoteTranscriptionJobStore

    init(
        api: any RemoteTranscriptionAPI,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        store: RemoteTranscriptionJobStore = RemoteTranscriptionJobStore(),
        uploadSessionFactory: UploadSessionFactory? = nil,
        transportRetryDelays: [Duration] = RemoteTranscriptionJobRunner.defaultTransportRetryDelays,
        localRetryDelays: [Duration] = RemoteTranscriptionJobRunner.defaultLocalRetryDelays
    ) {
        self.store = store
        self.transcriptions = transcriptions
        runner = RemoteTranscriptionJobRunner(
            api: api,
            downloads: downloads,
            transcriptions: transcriptions,
            store: store,
            uploadSessionFactory: uploadSessionFactory,
            transportRetryDelays: transportRetryDelays,
            localRetryDelays: localRetryDelays
        )
    }

    @discardableResult
    func start(episode: EpisodeListItemSnapshot, modelContext: ModelContext) -> StartOutcome {
        guard !transcriptions.hasCompletedTranscript(for: episode.episodeID) else {
            return .rejected("A transcript is already available for this episode.")
        }
        guard !store.hasActiveRequest else {
            return .rejected("Another remote transcription is in progress.")
        }
        guard store.existingReference(for: episode.episodeID)?.userCancelRequestedAt == nil else {
            return .rejected("The previous remote transcription is still being cancelled.")
        }

        let reservation: EpisodeTranscriptionWorkCoordinator.RemoteReservation
        switch transcriptions.workCoordinator.reserveRemote(
            episodeID: episode.episodeID,
            activeLocalEpisodeID: transcriptions.activeEpisodeID
        ) {
        case .success(let value):
            reservation = value
        case .failure(let conflict):
            return .rejected(conflict.localizedDescription)
        }
        guard let audioURL = episode.audioURL, audioURL.isEmpty == false else {
            store.begin(episodeID: episode.episodeID, title: episode.title)
            store.finish(phase: .failed(.missingAudio))
            transcriptions.workCoordinator.releaseRemote(reservation)
            return .started
        }

        pendingParkExit = nil
        store.begin(episodeID: episode.episodeID, title: episode.title)
        store.activeTask = Task { [weak self] in
            await self?.run(
                episode: episode,
                enclosureURL: audioURL,
                reservation: reservation,
                modelContext: modelContext
            )
        }
        return .started
    }

    /// Resume and Try Again: re-runs the episode against its persisted
    /// reference, so a parked or retryable job is re-attached by the same
    /// client request ID and never minted twice. A cleared reference (a
    /// terminal outcome) starts a fresh job.
    @discardableResult
    func resume(episode: EpisodeListItemSnapshot, modelContext: ModelContext) -> StartOutcome {
        store.dismissTerminalPhase(for: episode.episodeID)
        return start(episode: episode, modelContext: modelContext)
    }

    /// The user cancel. The intent is persisted before the local task is
    /// cancelled, the runner's cancel path then resolves the job (letting an
    /// in-flight create attach first) and sends at most one `/cancel`, and
    /// the reference is cleared only after that attempt is recorded. A
    /// repeated tap while that resolution is in flight does nothing.
    func cancel() {
        guard let episodeID = store.activeEpisodeID,
              let phase = store.phase,
              !phase.isTerminal,
              userCancelEpisodeID != episodeID
        else {
            return
        }
        store.recordUserCancelIntent(episodeID: episodeID, purpose: .transcription)
        let runTask = store.activeTask
        store.cancelActiveRequest()
        userCancelEpisodeID = episodeID
        userCancelTask = Task { [weak self, runner, store] in
            await runTask?.value
            _ = await runner.cancelServerJob(episodeID: episodeID, purpose: .transcription)
            // A cancel that landed after the durable import stopped nothing:
            // the run completed and the transcript is on this device, so the
            // completed phase stands.
            if store.activeEpisodeID == episodeID, store.phase != .completed {
                store.finish(phase: .cancelled)
            }
            if self?.userCancelEpisodeID == episodeID {
                self?.userCancelEpisodeID = nil
            }
        }
    }

    /// Stops local polling without any server decision: the reference keeps
    /// its job and records the exit, and the phase becomes resumable.
    func park(exit: RemoteTranscriptionJobExit) {
        guard let episodeID = store.activeEpisodeID,
              let phase = store.phase,
              !phase.isTerminal, !phase.isParked
        else {
            return
        }
        store.recordExit(exit, episodeID: episodeID, purpose: .transcription)
        guard store.activeTask != nil else {
            store.finish(phase: .parkedOnServer(exit))
            return
        }
        pendingParkExit = exit
        store.cancelActiveRequest()
    }

    private func run(
        episode: EpisodeListItemSnapshot,
        enclosureURL: String,
        reservation: EpisodeTranscriptionWorkCoordinator.RemoteReservation,
        modelContext: ModelContext
    ) async {
        defer {
            transcriptions.workCoordinator.releaseRemote(reservation)
        }
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
            if let exit = pendingParkExit {
                pendingParkExit = nil
                store.finish(phase: .parkedOnServer(exit))
            } else {
                store.finish(phase: .cancelled)
            }
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
        case .connectionLost:
            // The job is still running on the server; Resume re-attaches.
            .parkedOnServer(.connectionLost)
        default:
            .failed(error.failureCategory)
        }
    }
}
