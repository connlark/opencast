import Foundation
import OpenCastCore

/// Storage boundary for the device-local podcast/episode/refresh-log cache.
///
/// Subscriptions and playback progress are CloudKit-backed SwiftData models and
/// stay outside this boundary.
protocol LocalLibraryCacheStore: Sendable {
    /// `refreshLogs` in the returned snapshot is the per-feed projection
    /// (each feed's latest log, plus its latest success when the latest is a
    /// failure); the full retained history comes from `allRefreshLogs()`.
    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot
    /// Full retained refresh-log history, newest first (diagnostics surface).
    func allRefreshLogs() async throws -> [RefreshLogSnapshot]
    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot?
    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String]
    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws
    /// `artworkURL` is the URL string the preview was generated from; the write
    /// is skipped when the stored row's artwork URL no longer matches it.
    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws
    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws
    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws
    /// Conditional-request material persisted from the last full fetch;
    /// nil when the feed has none stored.
    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators?
    /// Persists validators without touching `updated_at` — an unchanged feed
    /// must not look content-changed.
    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws
    /// Every cached episode row for one feed, including rows that have
    /// departed the live feed; identity reconciliation diffs these against a
    /// fresh snapshot.
    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot]
    /// Deletes specific episode rows — used only for rows whose identity was
    /// migrated onto a successor; unmatched departed rows are retained.
    func deleteEpisodes(episodeIDs: [String]) async throws
    func deleteCache(forPodcastID podcastID: String) async throws
    func deleteAllLocalCache() async throws
    /// Server-reported notification poll health, replaced wholesale from each
    /// successful subscription sync (advisory UI data only).
    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws
    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth]
    func hasCompletedLegacyImport() async throws -> Bool
    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws
}
