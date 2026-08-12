#if DEBUG
import Foundation
import OpenCastCore

nonisolated struct UITestDelayedLocalLibraryCacheStore: LocalLibraryCacheStore {
    let base: any LocalLibraryCacheStore
    let loadDelay: Duration

    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        try await Task.sleep(for: loadDelay)
        return try await base.loadLibrary(activePodcastIDs: activePodcastIDs)
    }

    func allRefreshLogs() async throws -> [RefreshLogSnapshot] {
        try await base.allRefreshLogs()
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        try await base.episodeDetail(episodeID: episodeID)
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        try await base.showNotesHTMLByEpisodeID(activePodcastIDs: activePodcastIDs)
    }

    func prepareEpisodeSearchIndex() async throws {
        try await base.prepareEpisodeSearchIndex()
    }

    func setEpisodeSearchIndexRebuildHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) async {
        await base.setEpisodeSearchIndexRebuildHandler(handler)
    }

    func searchEpisodes(
        _ request: EpisodeSearchIndexRequest
    ) async throws -> [EpisodeSearchIndexHit] {
        try await base.searchEpisodes(request)
    }

    func replaceEpisodeTranscriptSearchDocument(
        _ document: EpisodeSearchTranscriptDocument
    ) async throws {
        try await base.replaceEpisodeTranscriptSearchDocument(document)
    }

    func removeEpisodeTranscriptSearchDocument(
        episodeID: String
    ) async throws {
        try await base.removeEpisodeTranscriptSearchDocument(
            episodeID: episodeID
        )
    }

    func reconcileEpisodeTranscriptSearchDocuments(
        retaining episodeIDs: Set<String>
    ) async throws {
        try await base.reconcileEpisodeTranscriptSearchDocuments(
            retaining: episodeIDs
        )
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {
        try await base.upsertCache(from: snapshot, refreshedAt: refreshedAt)
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {
        try await base.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
    }

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {
        try await base.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
    }

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {
        try await base.insertRefreshLog(log, prunedTo: retentionLimit)
    }

    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators? {
        try await base.feedValidators(forPodcastID: podcastID)
    }

    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws {
        try await base.updateFeedValidators(validators, forPodcastID: podcastID)
    }

    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot] {
        try await base.cachedEpisodes(forPodcastID: podcastID)
    }

    func deleteEpisodes(episodeIDs: [String]) async throws {
        try await base.deleteEpisodes(episodeIDs: episodeIDs)
    }

    func deleteCache(forPodcastID podcastID: String) async throws {
        try await base.deleteCache(forPodcastID: podcastID)
    }

    func deleteAllLocalCache() async throws {
        try await base.deleteAllLocalCache()
    }

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws {
        try await base.replaceNotificationFeedHealth(records)
    }

    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth] {
        try await base.notificationFeedHealthByFeedURL()
    }

    func hasCompletedLegacyImport() async throws -> Bool {
        try await base.hasCompletedLegacyImport()
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {
        try await base.importLegacyCache(podcasts: podcasts, episodes: episodes, refreshLogs: refreshLogs)
    }
}
#endif
