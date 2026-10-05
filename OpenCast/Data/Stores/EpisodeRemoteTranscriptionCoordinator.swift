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
    /// Every phase the request publishes, with its episode, so the system
    /// card can follow the run it was armed for.
    @ObservationIgnored var onPhaseChange: ((_ episodeID: String, _ phase: RemoteTranscriptionRequestPhase) -> Void)?
    /// A run's last phase, once per run, with the delivery owner snapshotted
    /// before the runner cleared the reference.
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

    /// A user's start. `prepareBackgroundSession` runs only once the episode
    /// is reserved and its run exists, so a rejected start never arms the
    /// system card.
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
            begin(episode)
            finish(
                .failed(.missingAudio),
                episodeID: episode.episodeID,
                deliveryOwner: store.completionDeliveryOwner(for: episode.episodeID)
            )
            transcriptions.workCoordinator.releaseRemote(reservation)
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

    /// Resume and Try Again: re-runs the episode against its persisted
    /// reference, so a parked or retryable job is re-attached by the same
    /// client request ID and never minted twice. A cleared reference (a
    /// terminal outcome) starts a fresh job.
    @discardableResult
    func resume(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        prepareBackgroundSession: (() -> Void)? = nil
    ) -> StartOutcome {
        store.dismissTerminalPhase(for: episode.episodeID)
        return start(episode: episode, modelContext: modelContext, prepareBackgroundSession: prepareBackgroundSession)
    }

    /// Launch and activation re-attach of the episode's kept reference
    /// (`RemoteJobReattacher`). A completed transcript refuses it unless that
    /// transcript is the reference's own imported result: the re-run then
    /// acks it (death after import) or accepts `acknowledged` (death after
    /// ack) and clears the reference. No user tapped anything, so the system
    /// card is never armed from here.
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

    /// A recovery trigger's retry of a persisted user cancel (CONTRACTS §4).
    /// While this coordinator's own cancel for the episode is still in
    /// flight, the trigger joins it rather than racing the tap's resolution;
    /// otherwise the runner resolves the same reference once. `episode` lets
    /// a create whose response was lost be replayed after a relaunch. Never
    /// starts polling.
    func resolvePendingUserCancel(episodeID: String, replaying episode: EpisodeListItemSnapshot?) async {
        if userCancelEpisodeID == episodeID, let userCancelTask {
            await userCancelTask.value
            return
        }
        _ = await runner.cancelServerJob(episodeID: episodeID, purpose: .transcription, replaying: episode)
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
                self?.onPhaseChange?(episodeID, .cancelled)
            }
            if self?.userCancelEpisodeID == episodeID {
                self?.userCancelEpisodeID = nil
            }
        }
    }

    /// Stops local polling without any server decision: the reference keeps
    /// its job and records the exit, and the phase becomes resumable. A park
    /// already in flight, or a user cancel, ends the run on its own, so a
    /// second park does nothing.
    /// Parks the live run: records the exit, stops polling and keeps the
    /// reference for Resume. Returns the run task that is now unwinding, so a
    /// caller that must outlive the run ending (the expiration handler, which
    /// completes the system task) can await it. Nil when no run was in flight
    /// or the park was refused.
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
            transcriptions.workCoordinator.releaseRemote(reservation)
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
