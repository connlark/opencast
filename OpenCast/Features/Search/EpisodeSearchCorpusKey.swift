import Foundation

/// Identity of the searched episode list, independent of query and mode. Used
/// to invalidate the session's fetched show-notes cache when episodes change.
nonisolated struct EpisodeSearchCorpusKey: Equatable, Sendable {
    let episodeCount: Int
    let newestEpisodeID: String?
    let oldestEpisodeID: String?
    let latestCachedAt: Date?
    let sourceRevision: Int?

    init(
        episodes: [EpisodeListItemSnapshot],
        sourceRevision: Int? = nil
    ) {
        episodeCount = episodes.count
        newestEpisodeID = episodes.first?.episodeID
        oldestEpisodeID = episodes.last?.episodeID
        self.sourceRevision = sourceRevision
        if sourceRevision == nil {
            latestCachedAt = episodes.reduce(nil) { latestCachedAt, episode in
                guard let latestCachedAt else {
                    return episode.cachedAt
                }

                return max(latestCachedAt, episode.cachedAt)
            }
        } else {
            latestCachedAt = nil
        }
    }
}
