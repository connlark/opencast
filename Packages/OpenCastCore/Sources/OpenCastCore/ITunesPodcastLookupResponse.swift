import Foundation

struct ITunesPodcastLookupResponse: Decodable, Sendable {
    var results: [ITunesPodcastLookupResult]
}
