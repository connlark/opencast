import Foundation

/// `id` is namespaced (`apple:…`, `podcastindex:…`) so it stays stable across providers.
public struct DirectoryPodcastResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String?
    public var genre: String?
    public var feedURL: URL?
    public var artworkURL: URL?
    public var collectionViewURL: URL?
    public var appleID: Int?
    public var podcastIndexID: Int?
    public var podcastGUID: String?
    /// Contributing providers, ranking authority first.
    public var sources: [PodcastDirectorySource]
    /// Unique candidate feeds in preference order (primary first).
    public var feedCandidates: [DirectoryFeedCandidate]

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        genre: String? = nil,
        feedURL: URL? = nil,
        artworkURL: URL? = nil,
        collectionViewURL: URL? = nil,
        appleID: Int? = nil,
        podcastIndexID: Int? = nil,
        podcastGUID: String? = nil,
        sources: [PodcastDirectorySource],
        feedCandidates: [DirectoryFeedCandidate]
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.genre = genre
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.collectionViewURL = collectionViewURL
        self.appleID = appleID
        self.podcastIndexID = podcastIndexID
        self.podcastGUID = podcastGUID
        self.sources = sources
        self.feedCandidates = feedCandidates
    }

    public init(
        id: Int,
        title: String,
        artistName: String? = nil,
        genre: String? = nil,
        feedURL: URL? = nil,
        artworkURL: URL? = nil,
        collectionViewURL: URL? = nil
    ) {
        self.init(
            id: "apple:\(id)",
            title: title,
            artistName: artistName,
            genre: genre,
            feedURL: feedURL,
            artworkURL: artworkURL,
            collectionViewURL: collectionViewURL,
            appleID: id,
            sources: [.apple],
            feedCandidates: feedURL.map { [DirectoryFeedCandidate(source: .apple, feedURL: $0)] } ?? []
        )
    }
}
