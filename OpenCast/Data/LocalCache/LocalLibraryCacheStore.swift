import Foundation
import OpenCastCore

/// Storage boundary for the device-local podcast/episode/refresh-log cache.
///
/// Subscriptions and playback progress are CloudKit-backed SwiftData models and
/// stay outside this boundary.
protocol LocalLibraryCacheStore: Sendable {
    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot
    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot?
    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String]
    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws
    /// `artworkURL` is the URL string the preview was generated from; the write
    /// is skipped when the stored row's artwork URL no longer matches it.
    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws
    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws
    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws
    func deleteCache(forPodcastID podcastID: String) async throws
    func deleteAllLocalCache() async throws
    func hasCompletedLegacyImport() async throws -> Bool
    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws
}
