import Foundation

public struct DirectoryPodcastResult: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var artistName: String?
    public var feedURL: URL?
    public var artworkURL: URL?
    public var collectionViewURL: URL?

    public init(
        id: Int,
        title: String,
        artistName: String? = nil,
        feedURL: URL? = nil,
        artworkURL: URL? = nil,
        collectionViewURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.collectionViewURL = collectionViewURL
    }
}
