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

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        try await base.episodeDetail(episodeID: episodeID)
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        try await base.showNotesHTMLByEpisodeID(activePodcastIDs: activePodcastIDs)
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

    func deleteCache(forPodcastID podcastID: String) async throws {
        try await base.deleteCache(forPodcastID: podcastID)
    }

    func deleteAllLocalCache() async throws {
        try await base.deleteAllLocalCache()
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
