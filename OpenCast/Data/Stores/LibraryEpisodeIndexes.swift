import Foundation

/// Build large-catalog lookup tables before publishing to SwiftUI. Keeping
/// these values together also avoids exposing partially rebuilt indexes.
nonisolated struct LibraryEpisodeIndexes: Sendable {
    let byID: [String: Int]
    let byPodcastID: [String: [Int]]
    let visibleIDs: Set<String>
    let latestContentChangeByPodcastID: [String: Date]
    /// Each show's dated episodes, newest publication first; undated
    /// episodes are omitted. Lets release-date lookups stop at the first
    /// episode older than what they need.
    let releaseOrderByPodcastID: [String: [Int]]

    init(episodes: [EpisodeListItemSnapshot]) {
        var byID: [String: Int] = [:]
        byID.reserveCapacity(episodes.count)
        var byPodcastID: [String: [Int]] = [:]
        var latestContentChangeByPodcastID: [String: Date] = [:]
        var datedByPodcastID: [String: [(publishedAt: Date, index: Int)]] = [:]
        for (index, episode) in episodes.enumerated() {
            if byID[episode.episodeID] == nil { byID[episode.episodeID] = index }
            byPodcastID[episode.podcastID, default: []].append(index)
            latestContentChangeByPodcastID[episode.podcastID] = max(
                latestContentChangeByPodcastID[episode.podcastID] ?? episode.cachedAt,
                episode.cachedAt
            )
            if let publishedAt = episode.publishedAt {
                datedByPodcastID[episode.podcastID, default: []].append((publishedAt, index))
            }
        }
        self.byID = byID
        self.byPodcastID = byPodcastID
        visibleIDs = Set(byID.keys)
        self.latestContentChangeByPodcastID = latestContentChangeByPodcastID
        // The cache already publishes newest-first, so this sort is normally
        // a linear pass; it keeps the lookups correct for any source order.
        releaseOrderByPodcastID = datedByPodcastID.mapValues { entries in
            entries
                .sorted { lhs, rhs in
                    lhs.publishedAt != rhs.publishedAt ? lhs.publishedAt > rhs.publishedAt : lhs.index < rhs.index
                }
                .map(\.index)
        }
    }

    @concurrent
    static func prepare(_ episodes: [EpisodeListItemSnapshot]) async throws -> Self {
        try Task.checkCancellation()
        let indexes = Self(episodes: episodes)
        try Task.checkCancellation()
        return indexes
    }
}
