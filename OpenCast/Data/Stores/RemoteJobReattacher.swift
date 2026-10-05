import Foundation
import SwiftData

/// Launch and scene-activation recovery for kept remote job references
/// (CONTRACTS §1, §4 and §7). Each trigger runs one pass, in order:
///
/// 1. Housekeeping drops only references older than the recovery window,
///    never a younger one because its `jobID` is absent, never one a live run
///    or the cloud queue still holds, and never mints a replacement.
/// 2. Each persisted user-cancel intent is retried once through the runner
///    the user's tap used, so a trigger racing a tap joins its resolution.
///    This is cleanup of an earlier user action: it never polls and never
///    mints a request ID.
/// 3. The newest eligible plain reference re-attaches through the
///    coordinator by its original client request ID. Cloud references stay
///    with the ad-free-pass queue, whose launch restore drains them.
///
/// A failed pass waits for the next trigger; nothing here runs on a timer.
final class RemoteJobReattacher {
    enum Trigger: Sendable {
        case launch
        case sceneActivated
    }

    private let plainTranscription: EpisodeRemoteTranscriptionCoordinator
    private let cloudRunner: RemoteTranscriptionJobRunner
    private let transcriptions: EpisodeTranscriptionStore
    private let resolveEpisode: (String) -> EpisodeListItemSnapshot?
    /// Episodes the ad-free-pass queue holds (pending or active). The queue
    /// owns those `.adDetection` references, and its absence of an active
    /// item is never proof that a server job is gone.
    private let cloudQueueEpisodeIDs: () -> Set<String>
    private var inFlight: Task<Void, Never>?

    private var store: RemoteTranscriptionJobStore {
        plainTranscription.store
    }

    init(
        plainTranscription: EpisodeRemoteTranscriptionCoordinator,
        cloudRunner: RemoteTranscriptionJobRunner,
        transcriptions: EpisodeTranscriptionStore,
        resolveEpisode: @escaping (String) -> EpisodeListItemSnapshot?,
        cloudQueueEpisodeIDs: @escaping () -> Set<String>
    ) {
        self.plainTranscription = plainTranscription
        self.cloudRunner = cloudRunner
        self.transcriptions = transcriptions
        self.resolveEpisode = resolveEpisode
        self.cloudQueueEpisodeIDs = cloudQueueEpisodeIDs
    }

    /// Starts one recovery pass, or returns the pass already running: a
    /// launch and an activation callback that race each other share it, so
    /// one reference is never started twice.
    @discardableResult
    func reattachIfNeeded(modelContext: ModelContext) -> Task<Void, Never> {
        if let inFlight {
            return inFlight
        }
        let pass = Task {
            await runPass(modelContext: modelContext)
            inFlight = nil
        }
        inFlight = pass
        return pass
    }

    private func runPass(modelContext: ModelContext) async {
        expireStaleReferences()
        await resolvePendingUserCancels()
        reattachNewestPlainReference(modelContext: modelContext)
    }

    private func expireStaleReferences() {
        let cloudQueue = cloudQueueEpisodeIDs()
        let liveEpisodeID = store.hasActiveRequest ? store.activeEpisodeID : nil
        for reference in store.references() where !reference.isWithinRecoveryWindow() {
            let isHeld = switch reference.resolvedPurpose {
            case .transcription: reference.episodeID == liveEpisodeID
            case .adDetection: cloudQueue.contains(reference.episodeID)
            }
            guard !isHeld else {
                continue
            }
            store.expireReference(for: reference.episodeID, purpose: reference.resolvedPurpose)
        }
    }

    private func resolvePendingUserCancels() async {
        for reference in store.references() where reference.userCancelRequestedAt != nil {
            let episode = resolveEpisode(reference.episodeID)
            switch reference.resolvedPurpose {
            case .transcription:
                await plainTranscription.resolvePendingUserCancel(
                    episodeID: reference.episodeID,
                    replaying: episode
                )
            case .adDetection:
                _ = await cloudRunner.cancelServerJob(
                    episodeID: reference.episodeID,
                    purpose: .adDetection,
                    replaying: episode
                )
            }
        }
    }

    private func reattachNewestPlainReference(modelContext: ModelContext) {
        let candidates = store.references()
            .filter { $0.resolvedPurpose == .transcription }
            .sorted { $0.createdAt > $1.createdAt }
        let cloudQueue = cloudQueueEpisodeIDs()
        for reference in candidates {
            let episode = resolveEpisode(reference.episodeID)
            if let skip = skipReason(for: reference, isResolved: episode != nil, cloudQueue: cloudQueue) {
                record(.reattachSkipped, reference, disposition: skip)
                continue
            }
            guard let episode else {
                continue
            }
            switch plainTranscription.reattach(episode: episode, modelContext: modelContext) {
            case .started:
                record(.reattachStarted, reference)
            case .rejected:
                // The episode reservation or another remote request owns the
                // lane; the next trigger tries again.
                record(.reattachSkipped, reference, disposition: .skippedActiveRequest)
            }
        }
    }

    /// Why a plain reference does not re-attach on this trigger, or nil.
    /// Once one reference starts, the request it owns makes every older one
    /// wait for a later trigger.
    private func skipReason(
        for reference: RemoteTranscriptionJobReference,
        isResolved: Bool,
        cloudQueue: Set<String>
    ) -> RemoteJobDiagnosticEvent.Disposition? {
        if reference.userCancelRequestedAt != nil {
            return .skippedCancelIntent
        }
        if reference.createState == .prepared {
            // No create ever left the process: there is no server job to
            // re-attach, and Try Again reuses the prepared ID.
            return .skippedNotCreated
        }
        if !isResolved {
            return .skippedUnresolvedEpisode
        }
        if store.hasActiveRequest || cloudQueue.contains(reference.episodeID) {
            return .skippedActiveRequest
        }
        if transcriptions.hasCompletedTranscript(for: reference.episodeID),
           !holdsOwnResult(reference) {
            return .skippedCompletedTranscript
        }
        return nil
    }

    /// The episode's transcript is this reference's own imported result: a
    /// death after import or after ack, which the re-run reconciles.
    private func holdsOwnResult(_ reference: RemoteTranscriptionJobReference) -> Bool {
        guard let jobID = reference.jobID else {
            return false
        }
        return transcriptions.importedRemoteDocument(jobID: jobID, for: reference.episodeID) != nil
    }

    private func record(
        _ kind: RemoteJobDiagnosticEvent.Kind,
        _ reference: RemoteTranscriptionJobReference,
        disposition: RemoteJobDiagnosticEvent.Disposition? = nil
    ) {
        store.diagnostics.record(RemoteJobDiagnosticEvent(
            component: .reattach,
            kind: kind,
            episodeID: reference.episodeID,
            jobID: reference.jobID,
            clientRequestID: reference.clientRequestID,
            purpose: reference.resolvedPurpose,
            disposition: disposition
        ))
    }
}
