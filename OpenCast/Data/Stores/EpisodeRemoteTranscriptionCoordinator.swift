import Foundation
import Observation
import OpenCastTranscription
import SwiftData

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
    /// One tap burst sends at most one `/cancel`: while this runs, further taps for its episode
    /// are no-ops.
    @ObservationIgnored private(set) var userCancelTask: Task<Void, Never>?
    @ObservationIgnored private var userCancelEpisodeID: String?
    @ObservationIgnored var onPhaseChange: ((_ episodeID: String, _ phase: RemoteTranscriptionRequestPhase) -> Void)?
    /// Called once per run.
    @ObservationIgnored var onRunEnded: ((
        _ episodeID: String,
        _ phase: RemoteTranscriptionRequestPhase,
        _ deliveryOwner: JobCompletionDeliveryOwner
    ) -> Void)?
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

    /// `prepareBackgroundSession` runs only once the run exists, so a rejected start never arms
    /// the system card.
    @discardableResult
    func start(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        prepareBackgroundSession: (() -> Void)? = nil
    ) -> StartOutcome {
        guard !transcriptions.hasCompletedTranscript(for: episode.episodeID) else {
            return .rejected("A transcript is already available for this episode.")
        }
        return launchRun(
            episode: episode,
            modelContext: modelContext,
            prepareBackgroundSession: prepareBackgroundSession
        )
    }

    private func launchRun(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        prepareBackgroundSession: (() -> Void)?
    ) -> StartOutcome {
        guard !store.hasActiveRequest else {
            return .rejected("Another remote transcription is in progress.")
        }
        guard store.existingReference(for: episode.episodeID)?.userCancelRequestedAt == nil else {
            return .rejected("The previous remote transcription is still being cancelled.")
        }

        let reservation: EpisodeTranscriptionWorkCoordinator.RemoteReservation
        switch transcriptions.reserveRemoteWork(for: episode.episodeID) {
        case .success(let value):
            reservation = value
        case .failure(let conflict):
            return .rejected(conflict.localizedDescription)
        }
        guard let audioURL = episode.audioURL, audioURL.isEmpty == false else {
            begin(episode)
            finish(
                .failed(.missingAudio),
                episodeID: episode.episodeID,
                deliveryOwner: store.completionDeliveryOwner(for: episode.episodeID)
            )
            transcriptions.releaseRemoteWork(reservation)
            return .started
        }

        pendingParkExit = nil
        begin(episode)
        store.activeTask = Task { [weak self] in
            await self?.run(
                episode: episode,
                enclosureURL: audioURL,
                reservation: reservation,
                modelContext: modelContext
            )
        }
        prepareBackgroundSession?()
        return .started
    }

    @discardableResult
    func resume(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        prepareBackgroundSession: (() -> Void)? = nil
    ) -> StartOutcome {
        store.dismissTerminalPhase(for: episode.episodeID)
        return start(episode: episode, modelContext: modelContext, prepareBackgroundSession: prepareBackgroundSession)
    }

    /// A completed transcript that is the reference's own import still re-runs, so a run that died
    /// after the import or after the ack finishes and clears the reference.
    @discardableResult
    func reattach(episode: EpisodeListItemSnapshot, modelContext: ModelContext) -> StartOutcome {
        if transcriptions.hasCompletedTranscript(for: episode.episodeID) {
            guard let jobID = store.existingReference(for: episode.episodeID)?.jobID,
                  transcriptions.importedRemoteDocument(jobID: jobID, for: episode.episodeID) != nil
            else {
                return .rejected("A transcript is already available for this episode.")
            }
        }
        return launchRun(episode: episode, modelContext: modelContext, prepareBackgroundSession: nil)
    }

    /// Joins this coordinator's own in-flight cancel for the episode rather than racing it.
    /// `episode` lets a create whose response was lost be replayed after a relaunch.
    func resolvePendingUserCancel(episodeID: String, replaying episode: EpisodeListItemSnapshot?) async {
        if userCancelEpisodeID == episodeID, let userCancelTask {
            await userCancelTask.value
            return
        }
        _ = await runner.cancelServerJob(episodeID: episodeID, purpose: .transcription, replaying: episode)
    }

    /// Persists the intent before cancelling the local task, and lets the run unwind so an
    /// in-flight create can attach before the runner sends `/cancel`.
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
            // A cancel that landed after the durable import stopped nothing: the completed phase stands.
            if store.activeEpisodeID == episodeID, store.phase != .completed {
                store.finish(phase: .cancelled)
                self?.onPhaseChange?(episodeID, .cancelled)
            }
            if self?.userCancelEpisodeID == episodeID {
                self?.userCancelEpisodeID = nil
            }
        }
    }

    /// Stops local polling without any server decision; the reference keeps its job for Resume.
    /// Returns the unwinding run task, or nil when no run was in flight or the park was refused.
    @discardableResult
    func park(exit: RemoteTranscriptionJobExit) -> Task<Void, Never>? {
        guard let episodeID = store.activeEpisodeID,
              let phase = store.phase,
              !phase.isTerminal, !phase.isParked,
              pendingParkExit == nil,
              userCancelEpisodeID != episodeID
        else {
            return nil
        }
        store.recordExit(exit, episodeID: episodeID, purpose: .transcription)
        guard let runTask = store.activeTask else {
            finish(
                .parkedOnServer(exit),
                episodeID: episodeID,
                deliveryOwner: store.completionDeliveryOwner(for: episodeID)
            )
            return nil
        }
        pendingParkExit = exit
        store.cancelActiveRequest()
        return runTask
    }

    private func run(
        episode: EpisodeListItemSnapshot,
        enclosureURL: String,
        reservation: EpisodeTranscriptionWorkCoordinator.RemoteReservation,
        modelContext: ModelContext
    ) async {
        defer {
            transcriptions.releaseRemoteWork(reservation)
        }
        let episodeID = episode.episodeID
        // Snapshotted before the run: a terminal server failure clears the
        // reference before its error arrives here.
        let deliveryOwner = store.completionDeliveryOwner(for: episodeID)
        do {
            let outcome = try await runner.run(
                episode: episode,
                enclosureURL: enclosureURL,
                purpose: .transcription,
                modelContext: modelContext,
                onEvent: { [weak self] event in
                    self?.publish(Self.phase(for: event), episodeID: episodeID)
                }
            )
            finish(.completed, episodeID: episodeID, deliveryOwner: outcome.completionDeliveryOwner)
        } catch is CancellationError {
            if let exit = pendingParkExit {
                pendingParkExit = nil
                finish(.parkedOnServer(exit), episodeID: episodeID, deliveryOwner: deliveryOwner)
            } else {
                finish(.cancelled, episodeID: episodeID, deliveryOwner: deliveryOwner)
            }
        } catch let error as RemoteTranscriptionJobRunError {
            finish(Self.terminalPhase(for: error), episodeID: episodeID, deliveryOwner: deliveryOwner)
        } catch {
            finish(.failed(.serviceUnavailable), episodeID: episodeID, deliveryOwner: deliveryOwner)
        }
    }

    private func begin(_ episode: EpisodeListItemSnapshot) {
        store.begin(episodeID: episode.episodeID, title: episode.title)
        if let phase = store.phase {
            onPhaseChange?(episode.episodeID, phase)
        }
    }

    private func publish(_ phase: RemoteTranscriptionRequestPhase, episodeID: String) {
        store.update(phase: phase)
        onPhaseChange?(episodeID, phase)
    }

    private func finish(
        _ phase: RemoteTranscriptionRequestPhase,
        episodeID: String,
        deliveryOwner: JobCompletionDeliveryOwner
    ) {
        store.finish(phase: phase)
        onPhaseChange?(episodeID, phase)
        onRunEnded?(episodeID, phase, deliveryOwner)
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
            // Plain jobs never request the ad phase; `.saving` is the nearest honest one.
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
