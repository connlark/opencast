import Foundation
import NowPlaying
import OpenCastCore
@testable import OpenCastPlayback
import Testing

@MainActor
@Suite("System Now Playing representation")
struct NowPlayingMediaSessionTests {
    @Test
    func podcastContentCarriesEpisodeMetadataAndFiniteDuration() throws {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: DefaultNowPlayingArtworkLoader())
        let episode = makeEpisode(duration: 300)
        adapter.publish(PlaybackSnapshot(state: .paused, currentEpisode: episode, position: 42, rate: 1.5), resolvedDuration: 180)
        let content = try #require(adapter.content as? PodcastContent)
        #expect(content.id == episode.id.rawValue)
        #expect(content.episodeTitle == episode.title)
        #expect(content.showName == episode.podcastTitle)
        #expect(content.releaseDate == episode.publishedAt)
        #expect(content.type == .audio)
        guard case .finite(let duration) = content.duration else {
            Issue.record("Expected finite duration")
            return
        }
        #expect(duration == 180)
        #expect(adapter.commands.count == 8)
        adapter.clear()
        #expect(adapter.content == nil)
        #expect(adapter.playbackSnapshot == nil)
        #expect(adapter.commands.isEmpty)
    }

    @Test(arguments: [Double?.none, .some(0), .some(-1), .some(.nan), .some(.infinity)])
    func unknownDurationDoesNotPublishFiniteContentOrSeeking(duration: Double?) throws {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: DefaultNowPlayingArtworkLoader())
        adapter.publish(PlaybackSnapshot(state: .buffering, currentEpisode: makeEpisode(duration: duration)), resolvedDuration: duration)
        let content = try #require(adapter.content as? PodcastContent)
        #expect(content.duration == nil)
        #expect(!adapter.availableCommands.contains(.seek))
        #expect(adapter.commands.count == 7)
    }

    @Test
    func playbackSnapshotKeepsSelectedRateAndSampleTime() {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: DefaultNowPlayingArtworkLoader())
        let episode = makeEpisode(duration: 300)
        for (state, expected): (PlaybackState, MediaPlaybackSnapshot.PlaybackState) in [
            (.playing, .playing(rate: 1.5)), (.paused, .paused), (.buffering, .buffering),
            (.loading, .paused), (.failed("network"), .paused), (.idle, .stopped)
        ] {
            let snapshot = PlaybackSnapshot(state: state, currentEpisode: episode, position: 42, rate: 1.5)
            adapter.publish(snapshot, resolvedDuration: nil)
            let timestamp = adapter.snapshotTimestamp
            #expect(adapter.playbackSnapshot == MediaPlaybackSnapshot(
                state: expected, defaultPlaybackRate: 1.5, elapsedTime: 42, timestamp: timestamp
            ))
            adapter.setSkipIntervals(backward: 45, forward: 60)
            adapter.publish(snapshot, resolvedDuration: nil)
            #expect(adapter.snapshotTimestamp == timestamp)
        }
    }

    private func makeEpisode(duration: Double?) -> Episode {
        Episode(
            id: EpisodeID(rawValue: "system-session-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/session.xml"),
            podcastTitle: "The Session Podcast", title: "An episode",
            publishedAt: Date(timeIntervalSince1970: 1_000), duration: duration
        )
    }
}
