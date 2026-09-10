import Foundation

/// Build large-catalog lookup tables before publishing to SwiftUI. Keeping
/// these values together also avoids exposing partially rebuilt indexes.
nonisolated struct LibraryEpisodeIndexes: Sendable {
    let byID: [String: Int]
    let byPodcastID: [String: [Int]]
    let visibleIDs: Set<String>
    let latestContentChangeByPodcastID: [String: Date]

    init(episodes: [EpisodeListItemSnapshot]) {
        var byID: [String: Int] = [:]
        byID.reserveCapacity(episodes.count)
        var byPodcastID: [String: [Int]] = [:]
        var latestContentChangeByPodcastID: [String: Date] = [:]
        for (index, episode) in episodes.enumerated() {
            if byID[episode.episodeID] == nil { byID[episode.episodeID] = index }
            byPodcastID[episode.podcastID, default: []].append(index)
            latestContentChangeByPodcastID[episode.podcastID] = max(
                latestContentChangeByPodcastID[episode.podcastID] ?? episode.cachedAt,
                episode.cachedAt
            )
        }
        self.byID = byID
        self.byPodcastID = byPodcastID
        visibleIDs = Set(byID.keys)
        self.latestContentChangeByPodcastID = latestContentChangeByPodcastID
    }

    @concurrent
    static func prepare(_ episodes: [EpisodeListItemSnapshot]) async throws -> Self {
        try Task.checkCancellation()
        let indexes = Self(episodes: episodes)
        try Task.checkCancellation()
        return indexes
    }
}
