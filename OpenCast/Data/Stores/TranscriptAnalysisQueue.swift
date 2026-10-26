import Foundation
import SwiftData

/// Chapters & Summary queue coordination: manual generate requests and
/// resumes of interrupted device runs queue here and drain one at a time
/// through the single-flight analysis store.
final class TranscriptAnalysisQueue {
    private let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    private let transcriptions: EpisodeTranscriptionStore
    private let library: LibraryStore
    /// Set by the app model once it is fully initialized; an episode that no
    /// longer resolves can never run.
    var resolveEpisode: (String) -> EpisodeListItemSnapshot? = { _ in nil }
    private(set) var pendingEpisodeIDs: [String] = []
    /// Episodes a listener asked for; every other entry is a resume.
    private var manualEpisodeIDs: Set<String> = []
    private var drainTask: Task<Void, Never>?

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
    /// creator-chapters gate) is re-checked before any provider call, and
    /// ineligible requests skip quietly.
    func generate(episodeID: String, modelContext: ModelContext) {
        manualEpisodeIDs.insert(episodeID)
        enqueue(episodeID: episodeID, atFront: true, modelContext: modelContext)
    }

    /// Resumes device runs that a background card expiry or a relaunch
    /// interrupted: every `.running` record the store holds without a live
    /// run re-runs with its run id, so a resumed trial run spends no second
    /// unit. Launch and every scene activation call this; the queue's dedupe
    /// and the store's single flight keep one run per episode.
    func resumeInterruptedRuns(modelContext: ModelContext) {
        for episodeID in transcriptAnalyses.resumableEpisodeIDs {
            enqueue(episodeID: episodeID, modelContext: modelContext)
        }
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
            guard let episodeID = nextEpisodeID() else {
                return
            }
            let isManual = manualEpisodeIDs.remove(episodeID) != nil
            await startEligibleAnalysis(
                episodeID: episodeID,
                isManual: isManual,
                modelContext: modelContext
            )
        }
    }

    /// The next entry to run, removed from the queue: a pending resume
    /// first. While an interrupted run waits for the next activation to
    /// resume it, every other entry waits too and the drain stops, so at
    /// most one record is ever left `.running` for a relaunch to resume.
    private func nextEpisodeID() -> String? {
        let resumable = transcriptAnalyses.resumableEpisodeIDs
        if let index = pendingEpisodeIDs.firstIndex(where: resumable.contains) {
            return pendingEpisodeIDs.remove(at: index)
        }
        guard resumable.isEmpty, !pendingEpisodeIDs.isEmpty else {
            return nil
        }
        return pendingEpisodeIDs.removeFirst()
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
    /// episode snapshot skips the run rather than sending nil titles. A
    /// resume that can no longer run ends its record as interrupted, so the
    /// episode never keeps a spinner for a run nothing will finish.
    private func startEligibleAnalysis(
        episodeID: String,
        isManual: Bool,
        modelContext: ModelContext
    ) async {
        guard !transcriptAnalyses.hasActiveJob else {
            return
        }
        let isResume = transcriptAnalyses.resumableEpisodeIDs.contains(episodeID)
        guard isManual || isResume else {
            return
        }
        guard transcriptions.record(for: episodeID)?.state == .completed,
              let episode = resolveEpisode(episodeID)
        else {
            abandonIfResume(isResume, episodeID: episodeID, modelContext: modelContext)
            return
        }

        // Creator metadata wins (D3): a feed-declared chapters document
        // suppresses generation for that episode entirely.
        if let detail = await library.episodeDetail(for: episodeID),
           detail.chaptersURL != nil {
            abandonIfResume(isResume, episodeID: episodeID, modelContext: modelContext)
            return
        }

        // A failed read leaves a resume for the next activation.
        guard let document = try? await transcriptions.loadDocument(for: episodeID),
              document.episodeID == episodeID
        else {
            return
        }
        if !isResume {
            guard await !transcriptAnalyses.hasCurrentCompletedAnalysis(for: document) else {
                return
            }
        }
        // The cancellation check closes the nuke race: a drain cancelled
        // between this method's awaits must never launch the (unstructured,
        // cancellation-blind) store task. The transcript state is rechecked
        // for the same reason: a transcript deleted while an await above was
        // suspended must stop the run here.
        guard transcriptions.record(for: episodeID)?.state == .completed,
              !transcriptAnalyses.hasActiveJob,
              !Task.isCancelled
        else {
            return
        }

        if isResume {
            transcriptAnalyses.resumeAnalysis(
                transcript: document,
                episodeTitle: episode.title,
                podcastTitle: episode.podcastTitle,
                modelContext: modelContext
            )
        } else {
            transcriptAnalyses.startAnalysis(
                transcript: document,
                episodeTitle: episode.title,
                podcastTitle: episode.podcastTitle,
                transcriptState: .completed,
                startedByListener: true,
                modelContext: modelContext
            )
        }
    }

    private func abandonIfResume(_ isResume: Bool, episodeID: String, modelContext: ModelContext) {
        guard isResume, !Task.isCancelled else {
            return
        }
        transcriptAnalyses.abandonResume(episodeID: episodeID, modelContext: modelContext)
    }
}
