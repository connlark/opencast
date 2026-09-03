import Foundation
import SwiftData

/// Chapters & Summary queue coordination (C3): manual generate requests and
/// deferred-retry sweeps queue here and drain one at a time through the
/// single-flight analysis store. The main context is captured at store load
/// because retry sweeps can fire from contexts that carry none of their own.
final class TranscriptAnalysisQueue {
    enum RetryTrigger {
        case sceneActivated
        /// Launch sweeps both deferral buckets without touching the
        /// once-per-foreground-session probe — the scene-activation probe
        /// can fire before the store load and must still get its turn.
        case launch
        /// A redeem credited the shared transcription balance: re-probe the
        /// pay-gate deferrals (H8). Cap deferrals stay parked — new credit
        /// cannot clear a daily cap.
        case balanceIncreased
    }

    private let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    private let transcriptions: EpisodeTranscriptionStore
    private let library: LibraryStore
    /// Set by the app model once it is fully initialized; a deferred record
    /// whose episode no longer resolves can never run.
    var resolveEpisode: (String) -> EpisodeListItemSnapshot? = { _ in nil }
    private var pendingEpisodeIDs: [String] = []
    private var drainTask: Task<Void, Never>?
    private var modelContext: ModelContext?
    private var hasProbedDeferredThisForegroundSession = false

    init(
        transcriptAnalyses: EpisodeTranscriptAnalysisStore,
        transcriptions: EpisodeTranscriptionStore,
        library: LibraryStore
    ) {
        self.transcriptAnalyses = transcriptAnalyses
        self.transcriptions = transcriptions
        self.library = library
    }

    /// Explicit episode-detail action for an already-transcribed episode —
    /// the only way a new analysis starts. Eligibility (current transcript,
    /// creator-chapters gate) is re-checked before any network call, and
    /// ineligible requests skip quietly.
    func generate(episodeID: String, modelContext: ModelContext) {
        self.modelContext = modelContext
        enqueue(episodeID: episodeID, atFront: true, modelContext: modelContext)
    }

    /// Re-probes deferred runs: typed daily-cap denials and pay-gate 402s
    /// queue rather than fail (a transcription backlog can legitimately hit
    /// the per-key cap; a long episode can legitimately outprice the
    /// balance). The scene-activation trigger probes at most once per
    /// foreground session, mirroring `AdFreePassCapDeferralPolicy`; a
    /// balance increase sweeps only the pay-gate bucket. Consent rides on
    /// the deferral buckets themselves: the store demotes any typed
    /// deferral that predates the generate disclosure acknowledgement at
    /// load, so these sweeps only ever re-upload manually started runs.
    func retryDeferred(modelContext: ModelContext, trigger: RetryTrigger) {
        if trigger == .sceneActivated {
            guard !hasProbedDeferredThisForegroundSession else {
                return
            }
        }
        self.modelContext = modelContext

        let deferredCandidateIDs: [String] = switch trigger {
        case .balanceIncreased:
            transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs
        case .sceneActivated, .launch:
            transcriptAnalyses.capDeferredEpisodeIDs
                + transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs
        }
        // The probe flag is consumed only when something was actually
        // enqueued: the first activation can precede the store load, and an
        // empty sweep must not spend the session's one probe. A deferred
        // record whose episode has left the library can never run, so it
        // must not spend the probe either.
        let deferredEpisodeIDs = deferredCandidateIDs.filter { episodeID in
            resolveEpisode(episodeID) != nil
        }
        guard !deferredEpisodeIDs.isEmpty else {
            return
        }
        if trigger == .sceneActivated {
            hasProbedDeferredThisForegroundSession = true
        }
        for episodeID in deferredEpisodeIDs {
            enqueue(episodeID: episodeID, modelContext: modelContext)
        }
    }

    func resetForegroundProbe() {
        hasProbedDeferredThisForegroundSession = false
    }

    /// Balance top-ups re-probe pay-gate deferrals (H8): the purchase store
    /// fires this after a redeem credits the shared balance. Before the
    /// first store load there is no context and nothing deferred to sweep.
    func retryDeferredAfterBalanceIncrease() {
        guard let modelContext else {
            return
        }
        retryDeferred(modelContext: modelContext, trigger: .balanceIncreased)
    }

    /// Stops the pending-analysis queue and waits for the drain to finish,
    /// so no suspended iteration can dequeue another episode afterwards.
    func cancelPending() async {
        pendingEpisodeIDs.removeAll()
        guard let drainTask else {
            return
        }
        drainTask.cancel()
        await drainTask.value
    }

    func resetAfterDataNuke() {
        pendingEpisodeIDs.removeAll()
    }

    private func enqueue(
        episodeID: String,
        atFront: Bool = false,
        modelContext: ModelContext
    ) {
        if !pendingEpisodeIDs.contains(episodeID) {
            if atFront {
                pendingEpisodeIDs.insert(episodeID, at: 0)
            } else {
                pendingEpisodeIDs.append(episodeID)
            }
        }
        drainPending(modelContext: modelContext)
    }

    private func drainPending(modelContext: ModelContext) {
        guard drainTask == nil else {
            return
        }
        drainTask = Task { [weak self] in
            await self?.runPending(modelContext: modelContext)
            self?.drainTask = nil
        }
    }

    private func runPending(modelContext: ModelContext) async {
        while !pendingEpisodeIDs.isEmpty {
            guard await waitForIdleStore() else {
                return
            }
            guard !pendingEpisodeIDs.isEmpty else {
                return
            }
            let episodeID = pendingEpisodeIDs.removeFirst()
            let recordStampBeforeRun = transcriptAnalyses.record(for: episodeID)?.updatedAt
            await startEligibleAnalysis(episodeID: episodeID, modelContext: modelContext)
            guard await waitForIdleStore() else {
                return
            }
            let record = transcriptAnalyses.record(for: episodeID)
            if let failureKind = record?.failureKind,
               failureKind == .capExceeded || failureKind == .insufficientSeconds,
               record?.updatedAt != recordStampBeforeRun {
                // This run was just denied by the worker. A cap denial would
                // deny every remaining run today; an insufficient-balance
                // denial would burn one daily-cap admission per queued
                // episode (denied reserves still consume admission), eating
                // the quota the post-top-up retries need. Stop draining —
                // the launch sweep, foreground probe, and balance-increase
                // sweep re-discover the backlog.
                // The stamp comparison matters: skip paths leave the record
                // untouched, so a stale denial from an earlier session must
                // not halt the queue behind it.
                pendingEpisodeIDs.removeAll()
                return
            }
        }
    }

    /// Returns false when cancelled.
    private func waitForIdleStore() async -> Bool {
        while transcriptAnalyses.hasActiveJob {
            let sequence = transcriptAnalyses.changeSequence
            guard transcriptAnalyses.hasActiveJob else {
                break
            }
            do {
                try await transcriptAnalyses.waitForChange(after: sequence)
            } catch {
                return false
            }
        }
        return true
    }

    /// Every guard exits quietly (fail-open): no chapters, no summary, never
    /// a user-facing error. Titles must be real (decision H2) — a missing
    /// episode snapshot skips the run rather than sending nil titles.
    private func startEligibleAnalysis(
        episodeID: String,
        modelContext: ModelContext
    ) async {
        guard transcriptions.record(for: episodeID)?.state == .completed,
              let episode = resolveEpisode(episodeID),
              transcriptAnalyses.canStartAnalysis,
              !transcriptAnalyses.hasActiveJob
        else {
            return
        }

        // Creator metadata wins (D3): a feed-declared chapters document
        // suppresses generation for that episode entirely.
        if let detail = await library.episodeDetail(for: episodeID),
           detail.chaptersURL != nil {
            return
        }

        guard let document = try? await transcriptions.loadDocument(for: episodeID),
              document.episodeID == episodeID
        else {
            return
        }
        guard await !transcriptAnalyses.hasCurrentCompletedAnalysis(for: document) else {
            return
        }
        // The cancellation check closes the nuke race: a drain cancelled
        // between this method's awaits must never launch the (unstructured,
        // cancellation-blind) store task. The transcript state is rechecked
        // for the same reason: a transcript deleted while an await above was
        // suspended must stop the upload here.
        guard transcriptions.record(for: episodeID)?.state == .completed,
              !transcriptAnalyses.hasActiveJob,
              !Task.isCancelled
        else {
            return
        }

        transcriptAnalyses.startAnalysis(
            transcript: document,
            episodeTitle: episode.title,
            podcastTitle: episode.podcastTitle,
            transcriptState: .completed,
            allowShared: TranscriptAnalysisFeatureFlags.isSharingEnabled,
            modelContext: modelContext
        )
    }
}
