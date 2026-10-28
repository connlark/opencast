import Foundation
import SwiftData

/// Auto Add to Up Next, Pocket Casts' model. Each show that is on keeps a
/// device-local release watermark: a pass queues the show's episodes
/// released after it that are unplayed, not queued, not playing and have
/// audio, oldest first, at the show's position and within the global limit,
/// then moves the watermark to the newest release whether or not each one
/// was queued, so a skipped episode is never retried. Turning a show on
/// queues nothing, and nothing older than the watermark is ever backfilled.
/// A pass is one synchronous main-actor stretch and runs only in the
/// foreground.
final class UpNextAutoAddCoordinator {
    private let library: LibraryStore
    private let upNextQueue: UpNextQueueStore
    private let settings: UpNextAutoAddSettingsStore
    private let isCurrentEpisode: (String) -> Bool
    private let now: () -> Date
    // Live per-scene activity, keyed by each root scene's lifecycle. With
    // several iPad windows, passes run while any of them is active.
    private var sceneActivity: [UUID: Bool] = [:]
    private var hasRegisteredScene = false

    /// `isCurrentEpisode` answers by episode ID.
    init(
        library: LibraryStore,
        upNextQueue: UpNextQueueStore,
        settings: UpNextAutoAddSettingsStore,
        isCurrentEpisode: @escaping (String) -> Bool,
        now: @escaping () -> Date = { .now }
    ) {
        self.library = library
        self.upNextQueue = upNextQueue
        self.settings = settings
        self.isCurrentEpisode = isCurrentEpisode
        self.now = now
    }

    /// Open while any root scene is active, and before any scene reports
    /// (callers without one, such as tests).
    var isForeground: Bool {
        hasRegisteredScene ? sceneActivity.values.contains(true) : true
    }

    /// Follows each root scene. Coming back to the foreground runs nothing
    /// by itself; activation maintenance runs a pass.
    func setScene(_ sceneID: UUID, isActive: Bool) {
        hasRegisteredScene = true
        sceneActivity[sceneID] = isActive
    }

    func removeScene(_ sceneID: UUID) {
        sceneActivity[sceneID] = nil
    }

    /// A position turns the show on or moves it; nil turns it off. A false
    /// leaves its message in the failing store's `lastErrorMessage`.
    @discardableResult
    func setPosition(
        _ position: UpNextAutoAddPosition?,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        let failure = savePosition(position, forPodcastID: podcastID, modelContext: modelContext) {
            library.setPodcastUpNextAutoAddPosition(position, feedURL: podcastID, modelContext: modelContext)
        }
        return failure == nil
    }

    /// Runs `saveSyncedValue`, the synced save that carries `position`,
    /// with the device-local watermark kept in step. Turning a show on
    /// writes its fresh watermark first (the newest release, or now when it
    /// has none, over any row left from an earlier time it was on), so the
    /// show turns on from this device only with a fresh baseline: a failed
    /// write stops before the save and leaves the show off, and a failed
    /// save after it removes the fresh row best-effort. After a save that
    /// keeps the show on, a missing row is written, so saving again repeats
    /// a failed write; after one that leaves it off, the row is removed.
    /// Returns nil once all of it is saved, else the message of the step
    /// that failed: the settings store's for a watermark write or removal,
    /// the library's for the synced save (`saveSyncedValue` is a
    /// `LibraryStore` save).
    @discardableResult
    func savePosition(
        _ position: UpNextAutoAddPosition?,
        forPodcastID podcastID: String,
        modelContext: ModelContext,
        savingSyncedValue saveSyncedValue: () -> Bool
    ) -> String? {
        let turnsOn = position != nil && library.podcastUpNextAutoAddPosition(forPodcastID: podcastID) == nil
        if turnsOn, !startWatermark(forPodcastID: podcastID, asOf: now(), modelContext: modelContext) {
            return failureMessage(settings.lastErrorMessage)
        }
        guard saveSyncedValue() else {
            if turnsOn {
                settings.removeWatermarks(forPodcastIDs: [podcastID], modelContext: modelContext)
            }
            return failureMessage(library.lastErrorMessage)
        }
        guard position != nil else {
            return settings.removeWatermark(forPodcastID: podcastID, modelContext: modelContext)
                ? nil
                : failureMessage(settings.lastErrorMessage)
        }
        guard !turnsOn, settings.watermark(forPodcastID: podcastID) == nil else {
            return nil
        }
        return startWatermark(forPodcastID: podcastID, asOf: now(), modelContext: modelContext)
            ? nil
            : failureMessage(settings.lastErrorMessage)
    }

    /// Every failing save leaves its store's message; the fallback only
    /// keeps a failure from reading as success.
    private func failureMessage(_ message: String?) -> String {
        message ?? "Unable to save playback settings."
    }

    /// Ignored while no scene is active. Ends by deleting the watermark
    /// rows of shows that are no longer on (turned off or unsubscribed on
    /// another device), so turning one on again heals at its newest release
    /// instead of queuing what came out while it was off. Returns the first
    /// failed queue save's message, taken from the queue store before a
    /// later success can clear it.
    @discardableResult
    func runPass(modelContext: ModelContext) -> String? {
        guard isForeground else {
            return nil
        }

        var firstFailureMessage: String?
        let asOf = now()
        let enabledPodcastIDs = library.upNextAutoAddPodcastIDs
        for podcastID in enabledPodcastIDs.sorted() {
            guard let position = library.podcastUpNextAutoAddPosition(forPodcastID: podcastID) else {
                continue
            }
            guard let watermark = settings.watermark(forPodcastID: podcastID) else {
                // Turned on by another device, or the row was lost: start at
                // the newest release with nothing queued.
                startWatermark(forPodcastID: podcastID, asOf: asOf, modelContext: modelContext)
                continue
            }

            let released = library.releasedEpisodes(forPodcastID: podcastID, publishedAfter: watermark, asOf: asOf)
            guard let newestRelease = released.first?.publishedAt else {
                continue
            }
            // A failed save keeps the watermark, so the next pass retries
            // the same episodes.
            guard enqueue(candidates(in: released), at: position, modelContext: modelContext) else {
                let message = upNextQueue.consumeLastErrorMessage()
                firstFailureMessage = firstFailureMessage ?? message
                continue
            }
            settings.setWatermark(newestRelease, forPodcastID: podcastID, modelContext: modelContext)
        }
        settings.removeWatermarks(
            forPodcastIDs: settings.watermarkPodcastIDs.subtracting(enabledPodcastIDs),
            modelContext: modelContext
        )
        return firstFailureMessage
    }

    @discardableResult
    private func startWatermark(forPodcastID podcastID: String, asOf: Date, modelContext: ModelContext) -> Bool {
        settings.setWatermark(
            library.newestReleasedEpisode(forPodcastID: podcastID, asOf: asOf)?.publishedAt ?? asOf,
            forPodcastID: podcastID,
            modelContext: modelContext
        )
    }

    /// Oldest first. Queue membership is left to the walk.
    private func candidates(in released: [EpisodeListItemSnapshot]) -> [EpisodeListItemSnapshot] {
        released.reversed().filter { episode in
            episode.audioURL != nil
                && !isCurrentEpisode(episode.episodeID)
                && !library.progressSummary(for: episode).isCompleted
        }
    }

    /// Pocket Casts' walk, oldest candidate first, against a copy of the
    /// live queue (earlier shows in this pass may have changed it), so each
    /// show's evictions and additions go in one save and a failure keeps
    /// every row. A candidate still in that copy when the walk reaches it
    /// is left out; one an earlier candidate evicted is not. Under the limit
    /// a candidate joins the batch. At the limit, a Top show under Only Add
    /// to Top removes the last queued row (or, once the queue is all batch,
    /// the batch's oldest) to make room; otherwise the candidate is left out
    /// for good.
    private func enqueue(
        _ candidates: [EpisodeListItemSnapshot],
        at position: UpNextAutoAddPosition,
        modelContext: ModelContext
    ) -> Bool {
        let limit = settings.limit.rawValue
        let replacesLastRow = position == .top && settings.limitReachedAction == .addToTopOnly
        var remaining = upNextQueue.items
        var batch: [EpisodeListItemSnapshot] = []
        var evicted: Set<String> = []
        for episode in candidates {
            guard !remaining.contains(where: { $0.episodeID == episode.episodeID }) else {
                continue
            }
            if remaining.count + batch.count < limit {
                batch.append(episode)
                continue
            }
            guard replacesLastRow else {
                continue
            }
            if let last = remaining.popLast() {
                evicted.insert(last.episodeID)
            } else {
                batch.removeFirst()
            }
            batch.append(episode)
        }

        switch position {
        case .top:
            return upNextQueue.enqueueNext(batch.reversed(), source: nil, evicting: evicted, modelContext: modelContext)
        case .bottom:
            return upNextQueue.enqueueLast(batch, source: nil, evicting: evicted, modelContext: modelContext)
        }
    }
}
