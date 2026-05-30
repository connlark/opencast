import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct NowPlayingInfoBuilderTests {
    private let builder = NowPlayingInfoBuilder()

    @Test
    func omitsDurationWhenNoFiniteDurationIsAvailable() throws {
        let snapshot = PlaybackSnapshot(
            state: .playing,
            currentEpisode: episode(duration: nil),
            position: 42,
            duration: nil,
            rate: 1.25
        )

        let info = try #require(builder.info(for: snapshot, resolvedDuration: nil, artwork: nil))

        #expect(info[MPMediaItemPropertyTitle] as? String == "Episode Title")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Podcast Title")
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(doubleValue(info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) == 42)
        #expect(floatValue(info[MPNowPlayingInfoPropertyPlaybackRate]) == 1.25)
        #expect(doubleValue(info[MPNowPlayingInfoPropertyDefaultPlaybackRate]) == 1)
        let mediaType = try #require(info[MPNowPlayingInfoPropertyMediaType] as? NSNumber)
        #expect(mediaType.intValue == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect((info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool) == false)
    }

    @Test
    func usesResolvedDurationAndClampsElapsedTimeWhilePlaying() throws {
        let snapshot = PlaybackSnapshot(
            state: .playing,
            currentEpisode: episode(duration: 240),
            position: 500,
            duration: 300,
            rate: 1.5
        )

        let info = try #require(builder.info(for: snapshot, resolvedDuration: 180, artwork: nil))

        #expect(doubleValue(info[MPMediaItemPropertyPlaybackDuration]) == 180)
        #expect(doubleValue(info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) == 180)
        #expect(floatValue(info[MPNowPlayingInfoPropertyPlaybackRate]) == 1.5)
    }

    @Test
    func preservesElapsedTimeAndPublishesZeroRateWhenPaused() throws {
        let snapshot = PlaybackSnapshot(
            state: .paused,
            currentEpisode: episode(duration: 300),
            position: 45,
            duration: 300,
            rate: 2
        )

        let info = try #require(builder.info(for: snapshot, resolvedDuration: nil, artwork: nil))

        #expect(doubleValue(info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) == 45)
        #expect(floatValue(info[MPNowPlayingInfoPropertyPlaybackRate]) == 0)
    }

    @Test
    func publishesZeroRateAndSanitizesElapsedTimeWhenFailed() throws {
        let snapshot = PlaybackSnapshot(
            state: .failed("network"),
            currentEpisode: episode(duration: 300),
            position: .infinity,
            duration: 300,
            rate: 2
        )

        let info = try #require(builder.info(for: snapshot, resolvedDuration: nil, artwork: nil))

        #expect(doubleValue(info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) == 0)
        #expect(floatValue(info[MPNowPlayingInfoPropertyPlaybackRate]) == 0)
    }
}
