import Foundation
import OpenCastCore

/// Artwork-preview resolution and persistence: leaf presentation state over
/// the core library surfaces. The backing stored properties (override map,
/// pending write chain) live in the class body with the rest of the
/// @Observable state.
extension LibraryStore {
    /// The row that resolved the preview shows it locally; the override box
    /// carries it to other appearances of the episode and the cache write
    /// persists it for the next full reload.
    func artworkPreview(for episode: EpisodeListItemSnapshot) -> ArtworkPreview? {
        if let override = episodeArtworkPreviewOverride(for: episode.episodeID).preview,
           override.matchesArtworkURLString(episode.artworkURL) {
            return override
        }
        return episode.artworkPreview
    }

    func artworkPreview(for podcast: PodcastCacheSnapshot) -> ArtworkPreview? {
        if let override = podcastArtworkPreviewOverride(for: podcast.feedURL).preview,
           override.matchesArtworkURLString(podcast.artworkURL) {
            return override
        }
        return podcast.artworkPreview
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
        episodeArtworkPreviewOverride(for: episodeID).preview = preview
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
              let storedPodcast = podcastCacheByFeedURL[podcast.feedURL],
              artworkPreview(for: storedPodcast)?.storageSignature != preview.storageSignature
        else {
            return false
        }

        let feedURL = podcast.feedURL
        podcastArtworkPreviewOverride(for: feedURL).preview = preview
        let artworkURL = podcast.artworkURL
        enqueueCacheWrite { localCache in
            try await localCache.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
        }
        return true
    }

    private func episodeArtworkPreviewOverride(for episodeID: String) -> ArtworkPreviewOverride {
        if let override = artworkPreviewOverridesByEpisodeID[episodeID] {
            return override
        }

        let override = ArtworkPreviewOverride()
        artworkPreviewOverridesByEpisodeID[episodeID] = override
        return override
    }

    private func podcastArtworkPreviewOverride(for feedURL: String) -> ArtworkPreviewOverride {
        if let override = artworkPreviewOverridesByFeedURL[feedURL] {
            return override
        }

        let override = ArtworkPreviewOverride()
        artworkPreviewOverridesByFeedURL[feedURL] = override
        return override
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
        pendingCacheWriteTask = Task {
            await previousTask?.value
            do {
                try await write(localCache)
            } catch {
                // Previews are disposable derived state; a failed persistence
                // write must not raise the modal Library Error alert.
                LibraryStore.backgroundFailureLogger.error(
                    "Artwork-preview cache write failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
