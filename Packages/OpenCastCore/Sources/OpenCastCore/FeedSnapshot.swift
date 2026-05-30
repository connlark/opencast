import Foundation

public struct FeedSnapshot: Codable, Hashable, Sendable {
    public var podcast: Podcast
    public var episodes: [Episode]
    public var fetchedAt: Date

    public init(podcast: Podcast, episodes: [Episode], fetchedAt: Date = .now) {
        self.podcast = podcast
        self.episodes = episodes
        self.fetchedAt = fetchedAt
    }
}
