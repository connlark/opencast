import Foundation

struct ITunesPodcastLookupResult: Decodable, Sendable {
    var collectionId: Int
    var collectionName: String
    var artistName: String?
    var primaryGenreName: String?
    var feedUrl: URL?
    var artworkUrl600: URL?
    var collectionViewUrl: URL?

    var directoryResult: DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: collectionId,
            title: collectionName,
            artistName: artistName,
            genre: primaryGenreName,
            feedURL: feedUrl,
            artworkURL: artworkUrl600,
            collectionViewURL: collectionViewUrl
        )
    }
}
