import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode share context")
struct EpisodeShareContextTests {
    private let base = URL(string: "https://opencast.mobile/e/")!

    @Test("The paused current episode offers its player position, floored to whole seconds")
    func pausedCurrentEpisodeUsesPlayerPosition() throws {
        let context = try #require(make(isCurrentEpisode: true, livePosition: 754.9, progress: progress(position: 12)))

        #expect(context.fixedStart?.label == "12:34")
        #expect(context.fixedStart?.url.query() == "t=754")
        #expect(context.url.query() == nil)
        #expect(context.fixedStart?.url.absoluteString == "\(context.url.absoluteString)?t=754")
    }

    @Test("The playing episode offers its position when shared, so the menu never changes as it plays")
    func playingEpisodeOffersCurrentTime() throws {
        let context = try #require(EpisodeShareContext.make(episode: snapshot(), playhead: .playing, baseURL: base))

        #expect(context.start == .currentTime)
        #expect(context.url(startingAt: 754.9).absoluteString == "\(context.url.absoluteString)?t=754")
        #expect(context.url(startingAt: 4_120.2).query() == "t=4120")
    }

    @Test(
        "A Current Time link the page would ignore falls back to the plain link",
        arguments: [0.9, .nan, 86_401] as [TimeInterval]
    )
    func currentTimeFallsBackToPlainLink(position: TimeInterval) throws {
        let context = try #require(EpisodeShareContext.make(episode: snapshot(), playhead: .playing, baseURL: base))

        #expect(context.url(startingAt: position) == context.url)
    }

    @Test("Another episode offers its saved progress when it is visible")
    func nonCurrentEpisodeUsesSavedProgress() throws {
        let context = try #require(make(isCurrentEpisode: false, livePosition: 99, progress: progress(position: 3_754.8)))

        #expect(context.fixedStart?.label == "1:02:34")
        #expect(context.fixedStart?.url.query() == "t=3754")
    }

    @Test(
        "No start link for a finished, unstarted, or barely started episode",
        arguments: [
            (false, 1_200, true),
            (false, 0.9, false),
            (true, 0.9, false),
            (true, .nan, false),
        ] as [(Bool, TimeInterval, Bool)]
    )
    func noStartVariant(isCurrentEpisode: Bool, position: TimeInterval, isCompleted: Bool) throws {
        let context = try #require(make(
            isCurrentEpisode: isCurrentEpisode,
            livePosition: position,
            progress: progress(position: position, isCompleted: isCompleted)
        ))

        #expect(context.fixedStart?.url == nil)
        #expect(context.fixedStart?.label == nil)
    }

    @Test("A start past the feed's duration is offered up to a day, and absurd positions never crash")
    func startBeyondTheEpisode() throws {
        // The snapshot says 4000 s, but dynamically inserted ads can make the
        // served file longer, so a playhead past that figure is real.
        let nearRSSDuration = try #require(make(isCurrentEpisode: true, livePosition: 3_998.7, progress: progress(position: 0)))
        #expect(nearRSSDuration.fixedStart?.url.query() == "t=3998")

        let pastRSSDuration = try #require(make(isCurrentEpisode: true, livePosition: 4_120.2, progress: progress(position: 0)))
        #expect(pastRSSDuration.fixedStart?.url.query() == "t=4120")
        #expect(pastRSSDuration.fixedStart?.label == "1:08:40")

        let savedPastRSSDuration = try #require(make(isCurrentEpisode: false, livePosition: 0, progress: progress(position: 4_120.5)))
        #expect(savedPastRSSDuration.fixedStart?.url.query() == "t=4120")

        let atDay = try #require(make(isCurrentEpisode: true, livePosition: 86_400.9, progress: progress(position: 0)))
        #expect(atDay.fixedStart?.url.query() == "t=86400")

        let pastDay = try #require(make(isCurrentEpisode: true, livePosition: 86_401, progress: progress(position: 0)))
        #expect(pastDay.fixedStart?.url == nil)

        let absurd = try #require(make(isCurrentEpisode: false, livePosition: 0, progress: progress(position: 1e19)))
        #expect(absurd.fixedStart?.url == nil)

        let unknownDuration = try #require(make(
            episode: snapshot(duration: nil),
            isCurrentEpisode: true,
            livePosition: 86_401,
            progress: progress(position: 0)
        ))
        #expect(unknownDuration.fixedStart?.url == nil)
    }

    @Test("The link encodes the snapshot, with the feed URL from the podcast ID")
    func linkEncodesSnapshot() throws {
        let context = try #require(make())
        let payload = try #require(EpisodeSharePayload(
            audioURL: "https://almanac.example.com/media/010-rubber-duck-final-witness.mp3",
            title: "Rubber Duck, Final Witness",
            podcastTitle: "The Example Almanac",
            artworkURL: "https://almanac.example.com/artwork/cover-v2.png",
            feedURL: "https://almanac.example.com/feed.xml",
            guid: "tag:example.com,2026:almanac:010-rubber-duck-final-witness",
            duration: 4_000,
            publishedAt: Date(timeIntervalSince1970: 1_778_590_800)
        ))

        #expect(context.url == (try EpisodeShareURL.url(base: base, payload: payload)))
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
            playhead: isCurrentEpisode ? .paused(livePosition) : .saved(progress ?? self.progress(position: 0)),
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

    private func snapshot(duration: TimeInterval? = 4_000) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: "episode-010",
            podcastID: "https://almanac.example.com/feed.xml",
            podcastTitle: "The Example Almanac",
            title: "Rubber Duck, Final Witness",
            summary: nil,
            publishedAt: Date(timeIntervalSince1970: 1_778_590_800),
            duration: duration,
            audioURL: "https://almanac.example.com/media/010-rubber-duck-final-witness.mp3",
            artworkURL: "https://almanac.example.com/artwork/cover-v2.png",
            artworkPreview: nil,
            guid: "tag:example.com,2026:almanac:010-rubber-duck-final-witness",
            cachedAt: Date(timeIntervalSince1970: 1_778_600_000)
        )
    }
}

private extension EpisodeShareContext {
    var fixedStart: (url: URL, label: String)? {
        guard case .fixed(let url, let label) = start else {
            return nil
        }
        return (url, label)
    }
}
