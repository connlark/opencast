import Foundation
import OpenCastCore
import Testing

@Suite("Episode share payload")
struct EpisodeSharePayloadTests {
    @Test("Line breaks and control characters become single spaces")
    func lineBreaksBecomeSpaces() throws {
        let payload = try #require(makePayload(
            title: "One\r\nTwo\nThree\u{2028}Four\tFive",
            podcastTitle: "Line\nBreak FM",
            guid: "guid\r1"
        ))

        #expect(payload.title == "One Two Three Four Five")
        #expect(payload.podcastTitle == "Line Break FM")
        #expect(payload.guid == "guid 1")
    }

    @Test("The crlf-title vector is what the app makes from CR/LF input")
    func crlfVectorComesFromRawInput() throws {
        let vector = try #require(EpisodeShareTokenVectors.load().vectors.first { $0.name == "crlf-title" })
        let payload = try #require(EpisodeSharePayload(
            audioURL: " \(vector.payload.audioURL)\n",
            title: "  Live from the Studio\r\nPart 2 ",
            podcastTitle: "Line Break\nFM",
            artworkURL: vector.payload.artworkURL,
            feedURL: vector.payload.feedURL,
            guid: "\(vector.payload.guid)\r\n",
            duration: 1799.6,
            publishedAt: Date(timeIntervalSince1970: 1_757_000_000.9)
        ))

        #expect(payload.tupleFields == vector.payload.fields)
    }

    @Test("Titles are trimmed and cut to 300 characters, guids to 512")
    func textIsTrimmedAndCapped() throws {
        let payload = try #require(makePayload(
            title: "  " + String(repeating: "a", count: 301) + "  ",
            podcastTitle: String(repeating: "é", count: 400),
            guid: String(repeating: "g", count: 600)
        ))

        #expect(payload.title == String(repeating: "a", count: 300))
        #expect(payload.podcastTitle.count == 300)
        #expect(payload.guid.count == 512)
        #expect(try #require(makePayload(title: "  Padded  ")).title == "Padded")
    }

    @Test("Caps count UTF-16 units, like the worker's limits, and never split a character")
    func capsCountUTF16Units() throws {
        let payload = try #require(makePayload(
            title: String(repeating: "a\u{301}\u{301}", count: 200),
            podcastTitle: String(repeating: "🇺🇸", count: 300),
            guid: String(repeating: "👨‍👩‍👧‍👦", count: 100)
        ))

        #expect(payload.title == String(repeating: "a\u{301}\u{301}", count: 100))
        #expect(payload.podcastTitle == String(repeating: "🇺🇸", count: 75))
        #expect(payload.guid == String(repeating: "👨‍👩‍👧‍👦", count: 46))
        #expect(payload.guid.utf16.count <= 512)
    }

    @Test("Audio hosts WHATWG would reject are refused")
    func audioHostsMatchWHATWG() {
        #expect(makePayload(audioURL: "https://example.com:70000/a.mp3") == nil)
        #expect(makePayload(audioURL: "https://999.1.1.1/a.mp3") == nil)
        #expect(makePayload(audioURL: "https://example.123/a.mp3") == nil)
        #expect(makePayload(audioURL: "https://example.com%20x/a.mp3") == nil)
        #expect(makePayload(audioURL: "https://192.0.2.10:8443/a.mp3") != nil)
        #expect(makePayload(audioURL: "https://example.com./a.mp3") != nil)
        #expect(makePayload(audioURL: "https://[2001:db8::1]/a.mp3") != nil)
    }

    @Test("An empty or whitespace-only title produces no payload")
    func emptyTitleProducesNoPayload() {
        #expect(makePayload(title: "") == nil)
        #expect(makePayload(title: " \n\t\u{2028} ") == nil)
    }

    @Test("Only http and https audio URLs with a host and at most 2048 characters are shareable")
    func audioURLRules() {
        #expect(makePayload(audioURL: nil) == nil)
        #expect(makePayload(audioURL: "") == nil)
        #expect(makePayload(audioURL: "file:///var/mobile/episode.mp3") == nil)
        #expect(makePayload(audioURL: "ftp://example.com/episode.mp3") == nil)
        #expect(makePayload(audioURL: "mailto:someone@example.com") == nil)
        #expect(makePayload(audioURL: "https:///no-host.mp3") == nil)
        #expect(makePayload(audioURL: "https://example.com/a\nb.mp3") == nil)
        #expect(makePayload(audioURL: "https://example.com/" + String(repeating: "a", count: 2029)) == nil)
        #expect(makePayload(audioURL: "https://example.com/" + String(repeating: "a", count: 2028))?.audioURL.count == 2048)
        #expect(makePayload(audioURL: "HTTP://EXAMPLE.COM/A.MP3")?.audioURL == "HTTP://EXAMPLE.COM/A.MP3")
    }

    @Test("The audio URL is the trimmed original string, not a re-encoded one")
    func audioURLKeepsOriginalSpelling() {
        let original = "https://example.com/show/My%20Episode.mp3?a=1&b=%7Bx%7D"

        #expect(makePayload(audioURL: "  \(original)\n")?.audioURL == original)
    }

    @Test("Invalid artwork and feed URLs become empty instead of blocking the share")
    func invalidOptionalURLsBecomeEmpty() throws {
        let payload = try #require(makePayload(
            artworkURL: "data:image/png;base64,AAAA",
            feedURL: "feed://example.com/rss"
        ))

        #expect(payload.artworkURL == "")
        #expect(payload.feedURL == "")
        #expect(try #require(makePayload(artworkURL: nil, guid: nil)).guid == "")
        #expect(try #require(makePayload(artworkURL: "https://example.com/" + String(repeating: "a", count: 2100))).artworkURL == "")
    }

    @Test("Durations round to whole seconds; unusable values become 0")
    func durationRules() {
        #expect(makePayload(duration: nil)?.durationSeconds == 0)
        #expect(makePayload(duration: .nan)?.durationSeconds == 0)
        #expect(makePayload(duration: .infinity)?.durationSeconds == 0)
        #expect(makePayload(duration: -5)?.durationSeconds == 0)
        #expect(makePayload(duration: 0.4)?.durationSeconds == 0)
        #expect(makePayload(duration: 1234.4)?.durationSeconds == 1234)
        #expect(makePayload(duration: 1234.9)?.durationSeconds == 1235)
        #expect(makePayload(duration: 9_999_999)?.durationSeconds == 9_999_999)
        #expect(makePayload(duration: 1e12)?.durationSeconds == 0)
    }

    @Test("Publish dates become whole Unix seconds; pre-1970 or unusable dates become 0")
    func publishedDateRules() {
        #expect(makePayload(publishedAt: nil)?.publishedUnix == 0)
        #expect(makePayload(publishedAt: Date(timeIntervalSince1970: -1))?.publishedUnix == 0)
        #expect(makePayload(publishedAt: Date(timeIntervalSince1970: 1_758_500_000.99))?.publishedUnix == 1_758_500_000)
        #expect(makePayload(publishedAt: .distantFuture)?.publishedUnix == 0)
    }

    @Test("init(episode:) maps the feed URL from the podcast ID")
    func initFromEpisode() throws {
        let episode = Episode(
            id: EpisodeID(rawValue: "episode"),
            podcastID: PodcastID(rawValue: "https://feeds.example.com/show.xml"),
            podcastTitle: "Show",
            title: "Episode",
            publishedAt: Date(timeIntervalSince1970: 1_758_500_000),
            duration: 61.2,
            audioURL: URL(string: "https://example.com/e.mp3"),
            artworkURL: URL(string: "https://example.com/e.jpg"),
            guid: "guid-1"
        )

        let payload = try #require(EpisodeSharePayload(episode: episode))

        #expect(payload.tupleFields == [
            "https://example.com/e.mp3",
            "Episode",
            "Show",
            "https://example.com/e.jpg",
            "https://feeds.example.com/show.xml",
            "guid-1",
            "61",
            "1758500000"
        ])
    }

    private func makePayload(
        audioURL: String? = "https://example.com/episode.mp3",
        title: String = "Episode",
        podcastTitle: String = "Show",
        artworkURL: String? = "https://example.com/art.jpg",
        feedURL: String? = "https://example.com/feed.xml",
        guid: String? = "guid",
        duration: TimeInterval? = 60,
        publishedAt: Date? = Date(timeIntervalSince1970: 1_758_500_000)
    ) -> EpisodeSharePayload? {
        EpisodeSharePayload(
            audioURL: audioURL,
            title: title,
            podcastTitle: podcastTitle,
            artworkURL: artworkURL,
            feedURL: feedURL,
            guid: guid,
            duration: duration,
            publishedAt: publishedAt
        )
    }
}
