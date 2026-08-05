import Foundation
import OpenCastCore

/// Artwork-preview resolution and persistence: leaf presentation state over
/// the core library surfaces. The backing stored properties (override map,
/// pending write chain) live in the class body with the rest of the
/// @Observable state.
extension LibraryStore {
    /// The row that resolved the preview shows it locally; the override map
    /// carries it to other appearances of the episode and the cache write
    /// persists it for the next full reload.
    func artworkPreview(for episode: EpisodeListItemSnapshot) -> ArtworkPreview? {
        if let override = artworkPreviewOverridesByEpisodeID[episode.episodeID],
           override.matchesArtworkURLString(episode.artworkURL) {
            return override
        }
        return episode.artworkPreview
    }

    @discardableResult
    func updateArtworkPreview(
        _ preview: ArtworkPreview,
        for episode: EpisodeListItemSnapshot
    ) -> Bool {
        guard preview.matchesArtworkURLString(episode.artworkURL),
              self.episode(with: episode.episodeID) != nil,
              artworkPreview(for: episode)?.storageSignature != preview.storageSignature
        else {
            return false
        }

        let episodeID = episode.episodeID
        artworkPreviewOverridesByEpisodeID[episodeID] = preview
        let artworkURL = episode.artworkURL
        enqueueCacheWrite { localCache in
            try await localCache.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
        }
        return true
    }

    @discardableResult
    func updateArtworkPreview(
        _ preview: ArtworkPreview,
        for podcast: PodcastCacheSnapshot
    ) -> Bool {
        guard activePodcastIDs.contains(podcast.feedURL),
              preview.matchesArtworkURLString(podcast.artworkURL),
              var storedPodcast = podcastCacheByFeedURL[podcast.feedURL],
              storedPodcast.artworkPreview?.storageSignature != preview.storageSignature
        else {
            return false
        }

        storedPodcast.artworkPreview = preview
        podcastCacheByFeedURL[podcast.feedURL] = storedPodcast
        let feedURL = podcast.feedURL
        let artworkURL = podcast.artworkURL
        enqueueCacheWrite { localCache in
            try await localCache.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
        }
        return true
    }

    /// Awaits queued asynchronous cache writes (artwork previews). Test hook.
    func waitForPendingCacheWrites() async {
        await pendingCacheWriteTask?.value
    }

    private func enqueueCacheWrite(
        _ write: @escaping @Sendable (any LocalLibraryCacheStore) async throws -> Void
    ) {
        let localCache = localCache
        let previousTask = pendingCacheWriteTask
        pendingCacheWriteTask = Task { [weak self] in
            await previousTask?.value
            do {
                try await write(localCache)
            } catch {
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
