import Foundation
import SwiftData

/// Chapters & Summary queue coordination (C3): manual generate requests and
/// deferred-retry sweeps queue here and drain one at a time through the
/// single-flight analysis store. The main context is captured at store load
/// because retry sweeps can fire from contexts that carry none of their own.
final class TranscriptAnalysisQueue {
    enum RetryTrigger {
        case sceneActivated
        /// Launch sweeps both deferral buckets without checking the
        /// once-per-foreground-session probe — the scene-activation probe
        /// can fire before the store load and must still get its turn.
        case launch
        /// The purchase store applied a balance with more headroom than the
        /// one it replaced: re-probe the pay-gate deferrals that balance now
        /// covers (H8). Cap deferrals stay parked — new credit cannot clear
        /// a daily cap.
        case balanceIncreased
    }

    /// The one in-flight pass over pay-gate deferrals. Overlapping triggers
    /// fold into it rather than refreshing the balance or reloading
    /// transcripts again; a trigger it cannot cover runs once afterwards.
    private struct CreditSweep {
        let generation: Int
        let refreshesBalance: Bool
        var hasReadBalance = false
        var followUpRefreshesBalance: Bool?
    }

    private let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    private let transcriptions: EpisodeTranscriptionStore
    private let library: LibraryStore
    private let purchases: RemoteTranscriptionPurchaseStore
    /// Set by the app model once it is fully initialized; a deferred record
    /// whose episode no longer resolves can never run.
    var resolveEpisode: (String) -> EpisodeListItemSnapshot? = { _ in nil }
    /// The transcript read a credit sweep waits on per episode. The app
    /// reads through the transcription store; tests hold a read open to
    /// land a denial or a reset while the sweep is suspended.
    var loadTranscriptDocument: (String) async throws -> EpisodeTranscriptDocument
    private(set) var pendingEpisodeIDs: [String] = []
    /// Manual Generate stays unfiltered: the worker decides, and its typed
    /// 402 renders the buy path.
    private var manualEpisodeIDs: Set<String> = []
    private var drainTask: Task<Void, Never>?
    private var modelContext: ModelContext?
    private var hasProbedDeferredThisForegroundSession = false
    private var creditSweep: CreditSweep?
    private var creditSweepTask: Task<Void, Never>?
    /// Bumped by cancellation and the data nuke so a sweep suspended across
    /// either can never enqueue afterwards.
    private var sweepGeneration = 0

    init(
        transcriptAnalyses: EpisodeTranscriptAnalysisStore,
        transcriptions: EpisodeTranscriptionStore,
        library: LibraryStore,
        purchases: RemoteTranscriptionPurchaseStore
    ) {
        self.transcriptAnalyses = transcriptAnalyses
        self.transcriptions = transcriptions
        self.library = library
        self.purchases = purchases
        loadTranscriptDocument = { episodeID in
            try await transcriptions.loadDocument(for: episodeID)
        }
    }

    /// Explicit episode-detail action for an already-transcribed episode —
    /// the only way a new analysis starts. Eligibility (current transcript,
    /// creator-chapters gate) is re-checked before any network call, and
    /// ineligible requests skip quietly.
    func generate(episodeID: String, modelContext: ModelContext) {
        self.modelContext = modelContext
        manualEpisodeIDs.insert(episodeID)
        enqueue(episodeID: episodeID, atFront: true, modelContext: modelContext)
    }

    /// Re-probes deferred runs: typed daily-cap denials and pay-gate 402s
    /// queue rather than fail (a transcription backlog can legitimately hit
    /// the per-key cap; a long episode can legitimately outprice the
    /// balance). Cap deferrals re-probe at launch and at most once per
    /// foreground session, mirroring `AdFreePassCapDeferralPolicy`. Pay-gate
    /// deferrals re-probe only when a known balance covers the episode's
    /// estimated charge: launch and foreground refresh the balance first,
    /// and a balance increase reads the balance it just applied. Consent
    /// rides on the deferral buckets themselves: the store demotes any typed
    /// deferral that predates the generate disclosure acknowledgement at
    /// load, so these sweeps only ever re-upload manually started runs.
    func retryDeferred(modelContext: ModelContext, trigger: RetryTrigger) {
        if trigger == .sceneActivated {
            guard !hasProbedDeferredThisForegroundSession else {
                return
            }
        }
        self.modelContext = modelContext

        let isSessionProbe = trigger != .balanceIncreased
        if isSessionProbe {
            // The probe is consumed only when something was actually
            // enqueued: the first activation can precede the store load, and
            // an empty sweep must not spend the session's one probe. A
            // deferred record whose episode has left the library can never
            // run, so it must not spend the probe either.
            let capEpisodeIDs = transcriptAnalyses.capDeferredEpisodeIDs.filter { episodeID in
                resolveEpisode(episodeID) != nil
            }
            if !capEpisodeIDs.isEmpty {
                hasProbedDeferredThisForegroundSession = true
            }
            for episodeID in capEpisodeIDs {
                enqueue(episodeID: episodeID, modelContext: modelContext)
            }
        }

        guard !creditRetryCandidateIDs().isEmpty else {
            return
        }
        requestCreditSweep(refreshesBalance: isSessionProbe)
    }

    func resetForegroundProbe() {
        hasProbedDeferredThisForegroundSession = false
    }

    /// Balance top-ups re-probe pay-gate deferrals (H8): the purchase store
    /// fires this after a redeem or refresh applies more headroom. Before
    /// the first store load there is no context and nothing deferred to
    /// sweep.
    func retryDeferredAfterBalanceIncrease() {
        guard let modelContext else {
            return
        }
        retryDeferred(modelContext: modelContext, trigger: .balanceIncreased)
    }

    /// Stops the pending-analysis queue and waits for the drain to finish,
    /// so no suspended iteration can dequeue another episode afterwards.
    func cancelPending() async {
        discardQueuedWork()
        guard let drainTask else {
            return
        }
        drainTask.cancel()
        await drainTask.value
    }

    func resetAfterDataNuke() {
        discardQueuedWork()
    }

    private func discardQueuedWork() {
        pendingEpisodeIDs.removeAll()
        manualEpisodeIDs.removeAll()
        discardCreditSweep()
    }

    /// Ends the in-flight credit pass and its follow-up: a pass suspended in
    /// a refresh or a transcript load sees the generation move and enqueues
    /// nothing afterwards.
    private func discardCreditSweep() {
        sweepGeneration += 1
        creditSweepTask?.cancel()
        creditSweepTask = nil
        creditSweep = nil
    }

    // MARK: - Pay-gate deferrals

    /// Deferred pay-gate records that could run now if the balance covers
    /// them; work already queued or running is never queued twice.
    private func creditRetryCandidateIDs() -> [String] {
        transcriptAnalyses.insufficientSecondsDeferredEpisodeIDs.filter { episodeID in
            resolveEpisode(episodeID) != nil
                && transcriptions.record(for: episodeID)?.state == .completed
                && !pendingEpisodeIDs.contains(episodeID)
                && !transcriptAnalyses.isRunning(for: episodeID)
        }
    }

    private func requestCreditSweep(refreshesBalance: Bool) {
        guard var sweep = creditSweep else {
            startCreditSweep(refreshesBalance: refreshesBalance)
            return
        }
        // A refreshing pass answers any later session probe. Any pass that
        // has not read the balance yet answers a balance increase, because
        // it reads the balance that increase already applied.
        let isCovered = refreshesBalance ? sweep.refreshesBalance : !sweep.hasReadBalance
        guard !isCovered else {
            return
        }
        sweep.followUpRefreshesBalance = (sweep.followUpRefreshesBalance ?? false) || refreshesBalance
        creditSweep = sweep
    }

    private func startCreditSweep(refreshesBalance: Bool) {
        let generation = sweepGeneration
        creditSweep = CreditSweep(generation: generation, refreshesBalance: refreshesBalance)
        creditSweepTask = Task { [weak self] in
            await self?.runCreditSweep(refreshesBalance: refreshesBalance, generation: generation)
            self?.finishCreditSweep(generation: generation)
        }
    }

    private func finishCreditSweep(generation: Int) {
        guard let sweep = creditSweep, sweep.generation == generation else {
            return
        }
        creditSweep = nil
        creditSweepTask = nil
        if let followUpRefreshesBalance = sweep.followUpRefreshesBalance,
           !creditRetryCandidateIDs().isEmpty {
            startCreditSweep(refreshesBalance: followUpRefreshesBalance)
        }
    }

    private func runCreditSweep(refreshesBalance: Bool, generation: Int) async {
        // A failed refresh proves nothing about credit: stale balance must
        // not wake a deferral, so the bucket waits for the next probe.
        if refreshesBalance {
            guard await purchases.refreshBalance() else {
                return
            }
        }
        guard isCurrentSweep(generation), purchases.balance != nil else {
            return
        }
        creditSweep?.hasReadBalance = true
        if refreshesBalance {
            // A fresh balance check is this session's probe of the pay-gate
            // bucket; later activations wait for a balance increase.
            hasProbedDeferredThisForegroundSession = true
        }

        for episodeID in creditRetryCandidateIDs() {
            guard let stamp = transcriptAnalyses.record(for: episodeID)?.updatedAt,
                  let document = try? await loadTranscriptDocument(episodeID)
            else {
                continue
            }
            guard isCurrentSweep(generation), let modelContext else {
                return
            }
            // Revalidate after the load: a manual run, a fresh denial, or a
            // drain may have moved this record while the read was suspended.
            guard document.episodeID == episodeID,
                  transcriptAnalyses.record(for: episodeID)?.updatedAt == stamp,
                  creditRetryCandidateIDs().contains(episodeID),
                  balanceCoversAnalysis(of: document)
            else {
                continue
            }
            enqueue(episodeID: episodeID, modelContext: modelContext)
        }
    }

    private func isCurrentSweep(_ generation: Int) -> Bool {
        generation == sweepGeneration && !Task.isCancelled
    }

    /// No balance means no evidence: the estimate alone would read the
    /// debt allowance as headroom.
    private func balanceCoversAnalysis(of document: EpisodeTranscriptDocument) -> Bool {
        purchases.balance != nil
            && purchases.analysisEstimate(transcript: document)?.fitsWithinHeadroom == true
    }

    // MARK: - Drain

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
            let isManual = manualEpisodeIDs.remove(episodeID) != nil
            let recordStampBeforeRun = transcriptAnalyses.record(for: episodeID)?.updatedAt
            await startEligibleAnalysis(
                episodeID: episodeID,
                isManual: isManual,
                modelContext: modelContext
            )
            guard await waitForIdleStore() else {
                return
            }
            let record = transcriptAnalyses.record(for: episodeID)
            if let failureKind = record?.failureKind,
               failureKind == .capExceeded || failureKind == .insufficientSeconds,
               record?.updatedAt != recordStampBeforeRun {
                // This run was just denied by the worker. A cap denial would
                // deny every remaining run today. An insufficient-balance
                // denial means the balance the queue relied on no longer
                // holds, so each further retry would spend a reserve call and
                // a full transcript upload only to be refused. Stop draining
                // and end the credit pass that may still be loading the next
                // transcript on that same balance — the launch sweep,
                // foreground probe, and balance-increase sweep re-discover
                // the backlog.
                // The stamp comparison matters: skip paths leave the record
                // untouched, so a stale denial from an earlier session must
                // not halt the queue behind it.
                pendingEpisodeIDs.removeAll()
                manualEpisodeIDs.removeAll()
                discardCreditSweep()
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
        isManual: Bool,
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
        // An automatic pay-gate retry rechecks the latest applied balance
        // right before uploading: runs queued ahead of it, or another
        // device, may have spent the headroom its sweep saw.
        if !isManual,
           let record = transcriptAnalyses.record(for: episodeID),
           record.state == .failed,
           record.failureKind == .insufficientSeconds,
           !balanceCoversAnalysis(of: document) {
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
