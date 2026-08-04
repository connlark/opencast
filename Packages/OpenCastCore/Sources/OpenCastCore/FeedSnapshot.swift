import Foundation

public struct FeedSnapshot: Codable, Hashable, Sendable {
    public var podcast: Podcast
    public var episodes: [Episode]
    public var fetchedAt: Date
    /// True when the parser salvaged the fully-parsed episodes from a document
    /// that failed to parse completely (truncation or a work-budget abort).
    public var isSalvaged: Bool
    /// The channel's `itunes:new-feed-url` declaration, when present.
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
