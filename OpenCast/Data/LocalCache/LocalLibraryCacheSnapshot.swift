import Foundation

nonisolated struct LocalLibraryCacheSnapshot: Sendable {
    let podcastsByFeedURL: [String: PodcastCacheSnapshot]
    let episodes: [EpisodeListItemSnapshot]
    let refreshLogs: [RefreshLogSnapshot]

    static let empty = LocalLibraryCacheSnapshot(
        podcastsByFeedURL: [:],
        episodes: [],
        refreshLogs: []
    )
}
