import Foundation

public struct Subscription: Codable, Hashable, Identifiable, Sendable {
    public var id: PodcastID {
        podcast.id
    }

    public var podcast: Podcast
    public var subscribedAt: Date

    public init(podcast: Podcast, subscribedAt: Date = .now) {
        self.podcast = podcast
        self.subscribedAt = subscribedAt
    }
}
