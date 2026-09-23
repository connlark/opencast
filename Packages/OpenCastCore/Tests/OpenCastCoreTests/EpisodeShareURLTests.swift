import Foundation
import OpenCastCore
import Testing

@Suite("Episode share URL")
struct EpisodeShareURLTests {
    @Test("The start time is a whole-second query only when at least one second")
    func startTimeQuery() throws {
        let payload = try samplePayload()
        let token = try EpisodeShareTokenEncoder.token(for: payload)
        let base = try #require(URL(string: "https://opencast.mobile/e/"))

        for start in [nil, 0, -3] as [Int?] {
            #expect(try EpisodeShareURL.url(base: base, payload: payload, startSeconds: start).absoluteString
                == "https://opencast.mobile/e/\(token)")
        }
        #expect(try EpisodeShareURL.url(base: base, payload: payload, startSeconds: 754).absoluteString
            == "https://opencast.mobile/e/\(token)?t=754")
    }

    @Test("A start the page would ignore is left off: past duration minus two seconds, or a day")
    func startBeyondTheEpisodeIsDropped() throws {
        let base = try #require(URL(string: "https://opencast.mobile/e/"))
        let payload = try samplePayload()
        let noDuration = try #require(EpisodeSharePayload(
            audioURL: "https://example.com/episode.mp3",
            title: "Episode",
            podcastTitle: "",
            artworkURL: nil,
            feedURL: nil,
            guid: nil,
            duration: nil,
            publishedAt: nil
        ))

        #expect(payload.maximumStartSeconds == 3598)
        #expect(try EpisodeShareURL.url(base: base, payload: payload, startSeconds: 3598).query() == "t=3598")
        #expect(try EpisodeShareURL.url(base: base, payload: payload, startSeconds: 3599).query() == nil)
        #expect(noDuration.maximumStartSeconds == 86_400)
        #expect(try EpisodeShareURL.url(base: base, payload: noDuration, startSeconds: 86_400).query() == "t=86400")
        #expect(try EpisodeShareURL.url(base: base, payload: noDuration, startSeconds: 86_401).query() == nil)
    }

    @Test("A base with or without a trailing slash yields the same link")
    func trailingSlashDoesNotMatter() throws {
        let payload = try samplePayload()
        let withSlash = try #require(URL(string: "https://opencast.mobile/e/"))
        let withoutSlash = try #require(URL(string: "https://opencast.mobile/e"))

        #expect(try EpisodeShareURL.url(base: withSlash, payload: payload, startSeconds: 5)
            == EpisodeShareURL.url(base: withoutSlash, payload: payload, startSeconds: 5))
    }

    @Test("Fixture vector URLs are reproduced exactly")
    func vectorURLs() throws {
        for vector in try EpisodeShareTokenVectors.load().vectors {
            let url = try EpisodeShareURL.url(
                base: EpisodeShareTokenVectors.shareBaseURL,
                payload: vector.payload.sharePayload(),
                startSeconds: vector.startTime
            )
            #expect(url.absoluteString == vector.url, "\(vector.name)")
        }
    }

    private func samplePayload() throws -> EpisodeSharePayload {
        try #require(EpisodeSharePayload(
            audioURL: "https://example.com/episode.mp3",
            title: "Episode",
            podcastTitle: "Show",
            artworkURL: nil,
            feedURL: nil,
            guid: nil,
            duration: 3600,
            publishedAt: nil
        ))
    }
}
