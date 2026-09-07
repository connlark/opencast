import Foundation
import OpenCastCore

nonisolated struct LocalLibraryCacheSnapshot: Sendable {
    let podcastsByFeedURL: [String: PodcastCacheSnapshot]
    let episodes: [EpisodeListItemSnapshot]
    let refreshLogs: [RefreshLogSnapshot]
    var incompleteFeeds: [String: FeedIncompleteReason] = [:]
    var processingRefreshPodcastIDs: Set<String> = []
    var automaticRetryAfterByFeedURL: [String: Date] = [:]

    static let empty = LocalLibraryCacheSnapshot(
        podcastsByFeedURL: [:],
        episodes: [],
        refreshLogs: []
    )
}
