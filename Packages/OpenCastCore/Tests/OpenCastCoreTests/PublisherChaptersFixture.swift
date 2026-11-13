import Foundation
import Testing

/// A `podcast:chapters` document a publisher actually served, saved byte for byte
/// under `Corpus/chapters/` so the decoder is pinned against real output, not only the spec.
/// Where each one came from is recorded in `Corpus/PROVENANCE.md`.
struct PublisherChaptersFixture: CustomTestStringConvertible {
    let resource: String
    let episodeTitle: String
    let fetchedAt: String
    let hostingPlatform: String
    let notes: String

    var testDescription: String { resource }

    func data() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Corpus/chapters")
        )
        return try Data(contentsOf: url)
    }
}
