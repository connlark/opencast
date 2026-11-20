import Foundation
import OpenCastCore

nonisolated protocol LocalLibraryCacheStore: Sendable {
    /// The snapshot's `refreshLogs` hold each feed's latest log, plus its latest success when
    /// the latest failed.
    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot
    /// Newest first.
    func allRefreshLogs() async throws -> [RefreshLogSnapshot]
    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot?
    /// Returns the entry whatever URL it came from: the caller compares `sourceURL` with the
    /// row's current `chapters_url`. Partial or undecodable entries read as nil.
    func publisherChapters(episodeID: String) async throws -> PublisherChaptersCacheEntry?
    /// Leaves `cached_at` alone, since a chapters fetch is not a content change. A no-op when
    /// the row is gone.
    func storePublisherChapters(_ entry: PublisherChaptersCacheEntry, episodeID: String) async throws
    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String]
    /// The summary is preferred over the show notes, each cut to `maximumCharacters`; rows with
    /// neither are omitted.
    func episodeSummaries(forPodcastID podcastID: String, maximumCharacters: Int) async throws -> [String: String]
    func prepareEpisodeSearchIndex() async throws
    /// The handler runs after the index is cleared and rebuilt. A rebuild restores only
    /// `episode_cache` metadata, so the transcript owner must re-reconcile its documents.
    func setEpisodeSearchIndexRebuildHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) async
    func searchEpisodes(
        _ request: EpisodeSearchIndexRequest
    ) async throws -> [EpisodeSearchIndexHit]
    func replaceEpisodeTranscriptSearchDocument(
        _ document: EpisodeSearchTranscriptDocument
    ) async throws
    func removeEpisodeTranscriptSearchDocument(
        episodeID: String
    ) async throws
    func reconcileEpisodeTranscriptSearchDocuments(
        retaining episodeIDs: Set<String>
    ) async throws
    func upsertCache(from prepared: PreparedFeed, refreshedAt: Date) async throws
    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws
    /// `artworkURL` is the URL string the preview was generated from; the write
    /// is skipped when the stored row's artwork URL no longer matches it.
    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws
    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws
    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws
    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators?
    /// Persists validators without touching `updated_at` — an unchanged feed
    /// must not look content-changed.
    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws
    /// Throttles the feed for one hour without advancing the partial-import counter or
    /// shortening an existing partial-import deadline.
    func recordFeedRetryFailure(forPodcastID podcastID: String, attemptedAt: Date) async throws
    func clearFeedRetryFailure(forPodcastID podcastID: String) async throws
    /// Includes rows that have departed the live feed.
    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot]
    func deleteEpisodes(episodeIDs: [String]) async throws
    func deleteCache(forPodcastID podcastID: String) async throws
    func deleteAllLocalCache() async throws
    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws
    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth]
    func hasCompletedLegacyImport() async throws -> Bool
    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws
}

extension LocalLibraryCacheStore {
    func upsertCache(from prepared: PreparedFeed, refreshedAt: Date) async throws {
        try await upsertCache(from: prepared.materialized(), refreshedAt: refreshedAt)
    }

    /// Show notes only: stores without a summary column fall back to them.
    func episodeSummaries(forPodcastID podcastID: String, maximumCharacters: Int) async throws -> [String: String] {
        try await showNotesHTMLByEpisodeID(activePodcastIDs: [podcastID])
            .compactMapValues { showNotes in
                let summary = String(showNotes.prefix(max(maximumCharacters, 0)))
                return summary.isEmpty ? nil : summary
            }
    }

    func publisherChapters(episodeID: String) async throws -> PublisherChaptersCacheEntry? {
        nil
    }

    func storePublisherChapters(_ entry: PublisherChaptersCacheEntry, episodeID: String) async throws {}

    func prepareEpisodeSearchIndex() async throws {}

    func setEpisodeSearchIndexRebuildHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) async {}

    func searchEpisodes(
        _ request: EpisodeSearchIndexRequest
    ) async throws -> [EpisodeSearchIndexHit] {
        throw EpisodeSearchIndexError.unavailable
    }

    func replaceEpisodeTranscriptSearchDocument(
        _ document: EpisodeSearchTranscriptDocument
    ) async throws {}

    func removeEpisodeTranscriptSearchDocument(
        episodeID: String
    ) async throws {}

    func reconcileEpisodeTranscriptSearchDocuments(
        retaining episodeIDs: Set<String>
    ) async throws {}

    func recordFeedRetryFailure(forPodcastID podcastID: String, attemptedAt: Date) async throws {}

    func clearFeedRetryFailure(forPodcastID podcastID: String) async throws {}
}
