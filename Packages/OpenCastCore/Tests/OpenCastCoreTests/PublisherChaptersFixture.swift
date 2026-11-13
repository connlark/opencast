import Foundation
import Testing

/// A `podcast:chapters` document a publisher actually served, saved byte for byte
/// under `Fixtures/` so the decoder is pinned against real output, not only the spec.
struct PublisherChaptersFixture: CustomTestStringConvertible {
    let resource: String
    let feedURL: String
    let episodeTitle: String
    /// The URL the feed item declares, which is what the app fetches.
    let documentURL: String
    let fetchedAt: String
    let hostingPlatform: String
    let notes: String

    var testDescription: String { resource }

    func data() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
