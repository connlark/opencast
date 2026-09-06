import Foundation

/// Build large-catalog lookup tables before publishing to SwiftUI. Keeping
/// these values together also avoids exposing partially rebuilt indexes.
nonisolated struct LibraryEpisodeIndexes: Sendable {
    let byID: [String: Int]
    let byPodcastID: [String: [Int]]
    let visibleIDs: Set<String>

    init(episodes: [EpisodeListItemSnapshot]) {
        var byID: [String: Int] = [:]
        byID.reserveCapacity(episodes.count)
        var byPodcastID: [String: [Int]] = [:]
        for (index, episode) in episodes.enumerated() {
            if byID[episode.episodeID] == nil { byID[episode.episodeID] = index }
            byPodcastID[episode.podcastID, default: []].append(index)
        }
        self.byID = byID
        self.byPodcastID = byPodcastID
        visibleIDs = Set(byID.keys)
    }

    @concurrent
    static func prepare(_ episodes: [EpisodeListItemSnapshot]) async throws -> Self {
        try Task.checkCancellation()
        let indexes = Self(episodes: episodes)
        try Task.checkCancellation()
        return indexes
    }
}
