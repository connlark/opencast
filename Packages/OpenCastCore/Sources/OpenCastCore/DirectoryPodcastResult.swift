import Foundation

/// A provider-neutral directory search result. `id` is a deterministic
/// namespaced string (`apple:…` / `podcastindex:…`) so merged and
/// appended results stay stable across providers.
public struct DirectoryPodcastResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String?
    /// The display/primary feed URL. Apple's wins on merged results.
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
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.collectionViewURL = collectionViewURL
        self.appleID = appleID
        self.podcastIndexID = podcastIndexID
        self.podcastGUID = podcastGUID
        self.sources = sources
        self.feedCandidates = feedCandidates
    }

    /// Compatibility initializer for Apple-sourced results, hardcoded
    /// suggestions, and existing tests: `id` is the Apple collection ID.
    public init(
        id: Int,
        title: String,
        artistName: String? = nil,
        feedURL: URL? = nil,
        artworkURL: URL? = nil,
        collectionViewURL: URL? = nil
    ) {
        self.init(
            id: "apple:\(id)",
            title: title,
            artistName: artistName,
            feedURL: feedURL,
            artworkURL: artworkURL,
            collectionViewURL: collectionViewURL,
            appleID: id,
            sources: [.apple],
            feedCandidates: feedURL.map { [DirectoryFeedCandidate(source: .apple, feedURL: $0)] } ?? []
        )
    }
}
