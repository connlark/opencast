import Foundation
import SwiftData

/// A pass is one synchronous main-actor stretch and runs only in the foreground.
final class UpNextAutoAddCoordinator {
    private let library: LibraryStore
    private let upNextQueue: UpNextQueueStore
    private let settings: UpNextAutoAddSettingsStore
    private let isCurrentEpisode: (String) -> Bool
    private let now: () -> Date
    // Keyed by root scene: with several iPad windows, passes run while any one is active.
    private var sceneActivity: [UUID: Bool] = [:]
    private var hasRegisteredScene = false

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

    var isForeground: Bool {
        hasRegisteredScene ? sceneActivity.values.contains(true) : true
    }

    func setScene(_ sceneID: UUID, isActive: Bool) {
        hasRegisteredScene = true
        sceneActivity[sceneID] = isActive
    }

    func removeScene(_ sceneID: UUID) {
        sceneActivity[sceneID] = nil
    }

    /// On false, the failing store's `lastErrorMessage` holds the message.
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

    /// Turning a show on writes its fresh watermark before the synced save, so the show is never
    /// on without a baseline; a failed save removes that row again. Returns nil, or the message
    /// of the step that failed.
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

    /// The fallback only keeps a failure from reading as success.
    private func failureMessage(_ message: String?) -> String {
        message ?? "Unable to save playback settings."
    }

    /// Deletes the watermarks of shows no longer on, so turning one on again starts at its
    /// newest release. Returns the first failed queue save's message, taken before a later
    /// success can clear it.
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

    /// Queue membership is left to the walk in `enqueue`, which can evict rows.
    private func candidates(in released: [EpisodeListItemSnapshot]) -> [EpisodeListItemSnapshot] {
        let archivedEpisodeIDs = library.archivedEpisodeIDs
        return released.reversed().filter { episode in
            episode.audioURL != nil
                && !isCurrentEpisode(episode.episodeID)
                && !archivedEpisodeIDs.contains(episode.episodeID)
                && !library.progressSummary(for: episode).isCompleted
        }
    }

    /// Walks a copy of the live queue, so each show's evictions and additions go in one save and
    /// a failure keeps every row. A candidate still in the copy is left out; one an earlier
    /// candidate evicted is not.
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
