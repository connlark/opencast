import Foundation

public struct FeedSnapshot: Codable, Hashable, Sendable {
    public var podcast: Podcast
    public var episodes: [Episode]
    public var fetchedAt: Date
    public var isSalvaged: Bool
    public var newFeedURL: URL?

    public init(
        podcast: Podcast,
        episodes: [Episode],
        fetchedAt: Date = .now,
        isSalvaged: Bool = false,
        newFeedURL: URL? = nil
    ) {
        self.podcast = podcast
        self.episodes = episodes
        self.fetchedAt = fetchedAt
        self.isSalvaged = isSalvaged
        self.newFeedURL = newFeedURL
    }
}
