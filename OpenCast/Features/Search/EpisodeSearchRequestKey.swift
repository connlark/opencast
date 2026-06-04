import Foundation

struct EpisodeSearchRequestKey: Equatable, Sendable {
    let query: String
    let mode: EpisodeSearchMode
    let episodeCount: Int
    let newestEpisodeID: String?
    let oldestEpisodeID: String?
    let latestCachedAt: Date?

    init(
        episodes: [EpisodeCacheRecord],
        query: String,
        mode: EpisodeSearchMode
    ) {
        self.query = query
        self.mode = mode
        episodeCount = episodes.count
        newestEpisodeID = episodes.first?.episodeID
        oldestEpisodeID = episodes.last?.episodeID
        latestCachedAt = episodes.reduce(nil) { latestCachedAt, episode in
            guard let latestCachedAt else {
                return episode.cachedAt
            }

            return max(latestCachedAt, episode.cachedAt)
        }
    }
}
