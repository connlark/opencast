import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode share context")
struct EpisodeShareContextTests {
    private let base = URL(string: "https://opencast.mobile/e/")!

    @Test("The current episode offers its live position, floored to whole seconds")
    func currentEpisodeUsesLivePosition() throws {
        let context = try #require(make(isCurrentEpisode: true, livePosition: 754.9, progress: progress(position: 12)))

        #expect(context.startLabel == "12:34")
        #expect(context.startURL?.query() == "t=754")
        #expect(context.url.query() == nil)
        #expect(context.startURL?.absoluteString == "\(context.url.absoluteString)?t=754")
    }

    @Test("A finished current episode still offers its live position")
    func currentEpisodeIgnoresCompletion() throws {
        let context = try #require(make(
            isCurrentEpisode: true,
            livePosition: 3_754.2,
            progress: progress(position: 3_754, isCompleted: true)
        ))

        #expect(context.startLabel == "1:02:34")
        #expect(context.startURL?.query() == "t=3754")
    }

    @Test("Another episode offers its saved progress when it is visible")
    func nonCurrentEpisodeUsesSavedProgress() throws {
        let context = try #require(make(isCurrentEpisode: false, livePosition: 99, progress: progress(position: 3_754.8)))

        #expect(context.startLabel == "1:02:34")
        #expect(context.startURL?.query() == "t=3754")
    }

    @Test("No start link for a finished, unstarted, or barely started episode")
    func noStartVariant() throws {
        let cases: [(Bool, TimeInterval, EpisodeProgressSummary)] = [
            (false, 0, progress(position: 1_200, isCompleted: true)),
            (false, 0, progress(position: 0)),
            (false, 0, progress(position: 0.9)),
            (true, 0.9, progress(position: 600)),
            (true, .nan, progress(position: 600)),
        ]
        for (isCurrentEpisode, livePosition, progress) in cases {
            let context = try #require(make(isCurrentEpisode: isCurrentEpisode, livePosition: livePosition, progress: progress))
            #expect(context.startURL == nil)
            #expect(context.startLabel == nil)
        }
    }

    @Test("No start link past what the page honours, and no crash on absurd positions")
    func startBeyondTheEpisode() throws {
        // The snapshot says 4000 s, so the page accepts starts up to 3998.
        let atLimit = try #require(make(isCurrentEpisode: true, livePosition: 3_998.7, progress: progress(position: 0)))
        #expect(atLimit.startURL?.query() == "t=3998")

        let pastLimit = try #require(make(isCurrentEpisode: true, livePosition: 3_999, progress: progress(position: 0)))
        #expect(pastLimit.startURL == nil)

        let savedPastLimit = try #require(make(isCurrentEpisode: false, livePosition: 0, progress: progress(position: 3_999.5)))
        #expect(savedPastLimit.startURL == nil)

        let absurd = try #require(make(isCurrentEpisode: false, livePosition: 0, progress: progress(position: 1e19)))
        #expect(absurd.startURL == nil)

        let unknownDuration = try #require(make(
            episode: snapshot(duration: nil),
            isCurrentEpisode: true,
            livePosition: 86_401,
            progress: progress(position: 0)
        ))
        #expect(unknownDuration.startURL == nil)
    }

    @Test("Episodes without a shareable audio URL or title produce no context")
    func unshareableEpisodes() {
        #expect(make(episode: snapshot(audioURL: nil)) == nil)
        #expect(make(episode: snapshot(audioURL: "file:///var/mobile/Downloads/episode.mp3")) == nil)
        #expect(make(episode: snapshot(title: " \n ")) == nil)
    }

    @Test("The link encodes the snapshot, with the feed URL from the podcast ID")
    func linkEncodesSnapshot() throws {
        let episode = snapshot()
        let context = try #require(make(episode: episode))
        let payload = try #require(EpisodeSharePayload(
            audioURL: episode.audioURL,
            title: episode.title,
            podcastTitle: episode.podcastTitle,
            artworkURL: episode.artworkURL,
            feedURL: episode.podcastID,
            guid: episode.guid,
            duration: episode.duration,
            publishedAt: episode.publishedAt
        ))

        #expect(context.url == (try EpisodeShareURL.url(base: base, payload: payload)))
        #expect(context.url.absoluteString.hasPrefix("https://opencast.mobile/e/1"))
        #expect(context.title == "Rubber Duck, Final Witness")
        #expect(context.artworkURL == URL(string: "https://almanac.example.com/artwork/cover-v2.png"))
    }

    private func make(
        episode: EpisodeListItemSnapshot? = nil,
        isCurrentEpisode: Bool = false,
        livePosition: TimeInterval = 0,
        progress: EpisodeProgressSummary? = nil
    ) -> EpisodeShareContext? {
        EpisodeShareContext.make(
            episode: episode ?? snapshot(),
            isCurrentEpisode: isCurrentEpisode,
            livePosition: livePosition,
            progress: progress ?? self.progress(position: 0),
            baseURL: base
        )
    }

    private func progress(position: TimeInterval, isCompleted: Bool = false) -> EpisodeProgressSummary {
        let duration: TimeInterval = 4_000
        return EpisodeProgressSummary(
            position: position,
            duration: duration,
            fractionCompleted: position / duration,
            remaining: duration - position,
            isCompleted: isCompleted
        )
    }

    private func snapshot(
        title: String = "Rubber Duck, Final Witness",
        audioURL: String? = "https://almanac.example.com/media/010-rubber-duck-final-witness.mp3",
        duration: TimeInterval? = 4_000
    ) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: "episode-010",
            podcastID: "https://almanac.example.com/feed.xml",
            podcastTitle: "The Example Almanac",
            title: title,
            summary: nil,
            publishedAt: Date(timeIntervalSince1970: 1_778_590_800),
            duration: duration,
            audioURL: audioURL,
            artworkURL: "https://almanac.example.com/artwork/cover-v2.png",
            artworkPreview: nil,
            guid: "tag:example.com,2026:almanac:010-rubber-duck-final-witness",
            cachedAt: Date(timeIntervalSince1970: 1_778_600_000)
        )
    }
}
