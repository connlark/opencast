import Foundation

public struct Podcast: Codable, Hashable, Identifiable, Sendable {
    public var id: PodcastID
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var summary: String?
    public var websiteURL: URL?
    public var artworkURL: URL?

    public init(
        id: PodcastID,
        feedURL: URL,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        websiteURL: URL? = nil,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.websiteURL = websiteURL
        self.artworkURL = artworkURL
    }
}
