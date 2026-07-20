import Foundation
import OpenCastCore
import Testing

@Suite("Episode identity")
struct EpisodeIdentityTests {
    // Changing these values requires a persisted-key and CloudKit migration.
    @Test("Pins canonical PodcastID output")
    func pinsCanonicalPodcastIDOutput() throws {
        let feedURL = try #require(URL(string: "HTTPS://EXAMPLE.COM/feed/?b=2&a=1#top"))

        #expect(URLCanonicalizer.podcastID(for: feedURL).rawValue == "https://example.com/feed?a=1&b=2")
    }

    @Test("Pins GUID EpisodeID output")
    func pinsGUIDEpisodeIDOutput() throws {
        let feedURL = try #require(URL(string: "HTTPS://EXAMPLE.COM/feed/?b=2&a=1#top"))
        let audioURL = try #require(URL(string: "https://ignored.example/audio.mp3"))

        let id = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: "  episode-guid-001  ",
            audioURL: audioURL,
            title: "Ignored title",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(id.rawValue == "0738a3f823ff61576bc7bebb78b62a5beab16e58498d769f8d266fd673966bc7")
    }

    @Test("Pins audio URL EpisodeID output")
    func pinsAudioURLEpisodeIDOutput() throws {
        let feedURL = try #require(URL(string: "HTTPS://EXAMPLE.COM/feed/?b=2&a=1#top"))
        let audioURL = try #require(
            URL(string: "HTTPS://CDN.EXAMPLE.COM/audio/episode.mp3/?z=9&a=1#play")
        )

        let id = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: "  ",
            audioURL: audioURL,
            title: "Ignored title",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(id.rawValue == "ecf7fb0eac77061d43973428365049d9f39f321b3c5860b96f844c92b62640e7")
    }

    @Test("Pins title and date EpisodeID output")
    func pinsTitleDateEpisodeIDOutput() throws {
        let feedURL = try #require(URL(string: "HTTPS://EXAMPLE.COM/feed/?b=2&a=1#top"))

        let id = EpisodeIdentity.makeID(
            feedURL: feedURL,
            guid: nil,
            audioURL: nil,
            title: "  Season \n Finale  ",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(id.rawValue == "70c3abbd2f61c0dc880e133f7654836f0b079ff122fe99765e9da6937b81fb5b")
    }

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
