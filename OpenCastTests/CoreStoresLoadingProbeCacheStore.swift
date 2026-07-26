import Foundation
import OpenCastCore
@testable import OpenCast

actor CoreStoresLoadingProbeCacheStore: LocalLibraryCacheStore {
    private let loadDelay: Duration
    private var loadCallCount = 0

    init(loadDelay: Duration) {
        self.loadDelay = loadDelay
    }

    func recordedLoadCount() -> Int {
        loadCallCount
    }

    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        loadCallCount += 1
        try await Task.sleep(for: loadDelay)
        return .empty
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        nil
    }

    func showNotesHTMLByEpisodeID(
        activePodcastIDs: Set<String>
    ) async throws -> [String: String] {
        [:]
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {}

    func updateEpisodeArtworkPreview(
        _ preview: ArtworkPreview,
        episodeID: String,
        artworkURL: String?
    ) async throws {}

    func updatePodcastArtworkPreview(
        _ preview: ArtworkPreview,
        feedURL: String,
        artworkURL: String?
    ) async throws {}

    func insertRefreshLog(
        _ log: RefreshLogSnapshot,
        prunedTo retentionLimit: Int
    ) async throws {}

    func deleteCache(forPodcastID podcastID: String) async throws {}

    func deleteAllLocalCache() async throws {}

    func hasCompletedLegacyImport() async throws -> Bool {
        true
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {}
}
