import Foundation
import SwiftData

final class TranscriptAnalysisQueue {
    private let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    private let transcriptions: EpisodeTranscriptionStore
    private let library: LibraryStore
    private let publisherChapters: PublisherChaptersStore
    var resolveEpisode: (String) -> EpisodeListItemSnapshot? = { _ in nil }
    private(set) var pendingEpisodeIDs: [String] = []
    /// Episodes a listener asked for; every other entry is a resume.
    private var manualEpisodeIDs: Set<String> = []
    private var drainTask: Task<Void, Never>?

    init(
        transcriptAnalyses: EpisodeTranscriptAnalysisStore,
        transcriptions: EpisodeTranscriptionStore,
        library: LibraryStore,
        publisherChapters: PublisherChaptersStore
    ) {
        self.transcriptAnalyses = transcriptAnalyses
        self.transcriptions = transcriptions
        self.library = library
        self.publisherChapters = publisherChapters
    }

    func generate(episodeID: String, modelContext: ModelContext) {
        manualEpisodeIDs.insert(episodeID)
        enqueue(episodeID: episodeID, atFront: true, modelContext: modelContext)
    }

    /// Safe to call on every activation: the queue's dedupe and the store's single flight keep
    /// one run per episode.
    func resumeInterruptedRuns(modelContext: ModelContext) {
        for episodeID in transcriptAnalyses.resumableEpisodeIDs {
            enqueue(episodeID: episodeID, modelContext: modelContext)
        }
    }

    /// Awaits the drain so no suspended iteration can dequeue another episode afterwards.
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

    /// Resumes go first, and while one waits for the next activation the drain stops, so at
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

    /// Every guard exits quietly. A resume that can no longer run ends its record as
    /// interrupted, so the episode never keeps a spinner for a run nothing will finish.
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

        // A feed-declared chapters document suppresses generation unless this device read it and
        // found it empty; one never read, or one that failed, still suppresses.
        if let documentURL = await library.episodeDetail(for: episodeID)?.chaptersURL,
           await !publisherChapters.isDocumentKnownEmpty(episodeID: episodeID, documentURL: documentURL) {
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
        // Rechecked after the awaits above: a data nuke or a transcript deletion may have landed
        // meanwhile, and the store task, once launched, ignores cancellation.
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
