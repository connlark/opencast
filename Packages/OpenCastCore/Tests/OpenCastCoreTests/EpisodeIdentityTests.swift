import Foundation
import OpenCastCore
import Testing

@Suite("Episode identity")
struct EpisodeIdentityTests {
    @Test("Uses RSS GUID when present")
    func usesGUID() throws {
        let feedURL = URL(string: "https://feeds.example.com/example-current-affairs.xml")!

        let first = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: "example-guid-001",
            audioURL: URL(string: "https://example.com/audio/changed.mp3"),
            title: "Changed",
            publishedAt: .now
        )
        let second = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: "example-guid-001",
            audioURL: URL(string: "https://example.com/audio/example-001.mp3"),
            title: "Episode With GUID",
            publishedAt: .distantPast
        )

        #expect(first == second)
    }

    @Test("Falls back to audio URL when GUID is missing")
    func fallsBackToAudioURL() throws {
        let feedURL = URL(string: "https://feeds.example.com/example-current-affairs.xml")!

        let first = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: nil,
            audioURL: URL(string: "https://example.com/audio/example-002.mp3"),
            title: "Original",
            publishedAt: .now
        )
        let second = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: "",
            audioURL: URL(string: "https://example.com/audio/example-002.mp3"),
            title: "Retitled",
            publishedAt: .distantPast
        )

        #expect(first == second)
    }
}
