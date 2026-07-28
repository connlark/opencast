import Intents
import Testing
@testable import OpenCast

@Suite("Siri donation builder")
struct SiriDonationBuilderTests {
    @Test("Donations describe the show without exposing an individual episode")
    func showLevelPayload() throws {
        let first = SiriDonationBuilder.interaction(for: episode(id: "one"))
        let second = SiriDonationBuilder.interaction(for: episode(id: "two"))
        let firstIntent = try #require(first.intent as? INPlayMediaIntent)
        let secondIntent = try #require(second.intent as? INPlayMediaIntent)
        let firstShow = try #require(firstIntent.mediaContainer)
        let secondShow = try #require(secondIntent.mediaContainer)

        #expect(first.groupIdentifier == "https://example.com/show.xml")
        #expect(second.groupIdentifier == first.groupIdentifier)
        #expect(firstIntent.mediaItems == nil)
        #expect(secondIntent.mediaItems == nil)
        #expect(firstShow.identifier == "https://example.com/show.xml")
        #expect(secondShow.identifier == firstShow.identifier)
        #expect(firstShow.title == "Example Show")
        #expect(firstShow.type == .podcastShow)
        #expect(firstShow.artist == nil)
    }

    private func episode(id: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "https://example.com/show.xml",
            podcastTitle: "Example Show",
            title: "Episode \(id)",
            summary: nil,
            publishedAt: nil,
            duration: 60,
            audioURL: "https://example.com/\(id).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: id,
            cachedAt: .now
        )
    }
}
