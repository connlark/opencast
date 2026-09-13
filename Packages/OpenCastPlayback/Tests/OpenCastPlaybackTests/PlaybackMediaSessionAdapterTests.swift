import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct PlaybackMediaSessionAdapterTests {
    @Test(arguments: [PlaybackState.idle, .loading, .buffering, .playing, .paused, .failed("network")])
    func publishedValuesMatchLegacy(state: PlaybackState) throws {
        let samples: [(duration: Double?, position: Double, rate: Float)] = [
            (nil, 42, 1.25), (300, 42, 2), (300, 500, 1.5), (0, -10, 0),
            (-1, .nan, .nan), (.nan, .infinity, .infinity), (.infinity, -.infinity, -1)
        ]
        for sample in samples {
            var current = episode(duration: sample.duration)
            current.publishedAt = Date(timeIntervalSince1970: 1_000)
            let snapshot = PlaybackSnapshot(
                state: state, currentEpisode: current, position: sample.position,
                duration: sample.duration, rate: sample.rate
            )
            let values = try #require(PlaybackMediaSessionValues(snapshot, resolvedDuration: nil))
            let legacy = try #require(NowPlayingInfoBuilder().info(
                for: snapshot, resolvedDuration: nil, artwork: nil
            ))
            #expect(values.title == legacy[MPMediaItemPropertyTitle] as? String)
            #expect(values.showName == legacy[MPMediaItemPropertyArtist] as? String)
            #expect(values.duration == doubleValue(legacy[MPMediaItemPropertyPlaybackDuration]))
            #expect(values.elapsedTime == doubleValue(legacy[MPNowPlayingInfoPropertyElapsedPlaybackTime]))
            #expect(values.playbackRate == floatValue(legacy[MPNowPlayingInfoPropertyPlaybackRate]))
            #expect(values.defaultPlaybackRate == floatValue(legacy[MPNowPlayingInfoPropertyDefaultPlaybackRate]))
            #expect(values.episodeID == current.id)
            #expect(values.releaseDate == current.publishedAt)
        }
    }

    @Test
    func resolvedDurationTakesPrecedence() throws {
        let values = try #require(PlaybackMediaSessionValues(
            PlaybackSnapshot(currentEpisode: episode(duration: 240), position: 500, duration: 300),
            resolvedDuration: 180
        ))
        #expect(values.duration == 180)
        #expect(values.elapsedTime == 180)
    }

    @Test
    func commandsRouteOnceThroughExistingHandlers() throws {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: ImmediateArtworkLoader())
        var actions: [String] = []
        adapter.install(RemoteCommandHandlers(
            play: { actions.append("play") }, pause: { actions.append("pause") },
            togglePlayPause: { actions.append("toggle") },
            skipForward: { actions.append("forward") }, skipBackward: { actions.append("backward") },
            nextTrack: { actions.append("next") },
            seek: { actions.append("seek \($0)") }, changeRate: { actions.append("rate \($0)") }
        ))
        adapter.publish(PlaybackSnapshot(state: .paused, currentEpisode: episode(duration: 180)), resolvedDuration: nil)
        try adapter.perform(.play)
        try adapter.perform(.togglePlayPause)
        try adapter.perform(.skipForward)
        try adapter.perform(.skipBackward)
        try adapter.perform(.previous)
        try adapter.perform(.next)
        try adapter.perform(.seek(500))
        try adapter.perform(.seek(-10))
        try adapter.perform(.changeRate(1.5))
        adapter.publish(PlaybackSnapshot(state: .buffering, currentEpisode: episode(duration: 180)), resolvedDuration: nil)
        try adapter.perform(.pause)
        #expect(actions == ["play", "toggle", "forward", "backward", "backward", "next", "seek 180.0", "seek 0.0", "rate 1.5", "pause"])
    }

    @Test
    func rejectedCommandsDoNotReachPlayback() {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: ImmediateArtworkLoader())
        var calls = 0
        adapter.install(RemoteCommandHandlers(
            play: { calls += 1 }, pause: { calls += 1 }, togglePlayPause: { calls += 1 },
            skipForward: { calls += 1 }, skipBackward: { calls += 1 }, nextTrack: { calls += 1 },
            seek: { _ in calls += 1 }, changeRate: { _ in calls += 1 }
        ))
        #expect(throws: PlaybackMediaSessionAdapter.CommandError.unavailable) { try adapter.perform(.play) }
        adapter.publish(PlaybackSnapshot(state: .playing, currentEpisode: episode(duration: nil)), resolvedDuration: nil)
        #expect(throws: PlaybackMediaSessionAdapter.CommandError.unavailable) { try adapter.perform(.seek(10)) }
        #expect(throws: PlaybackMediaSessionAdapter.CommandError.unavailable) { try adapter.perform(.play) }
        adapter.publish(PlaybackSnapshot(state: .paused, currentEpisode: episode(duration: 300)), resolvedDuration: nil)
        for position: Double in [.nan, .infinity, -.infinity] {
            #expect(throws: PlaybackMediaSessionAdapter.CommandError.invalidValue) { try adapter.perform(.seek(position)) }
        }
        for rate: Float in [0, -1, .nan, .infinity] {
            #expect(throws: PlaybackMediaSessionAdapter.CommandError.invalidValue) { try adapter.perform(.changeRate(rate)) }
        }
        adapter.clear()
        #expect(throws: PlaybackMediaSessionAdapter.CommandError.unavailable) { try adapter.perform(.seek(10)) }
        #expect(calls == 0)
    }

    @Test
    func completionReplayAndDismissalKeepSessionIdentity() throws {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: ImmediateArtworkLoader())
        let identity = adapter.id
        let current = episode(duration: 300)
        for (state, position): (PlaybackState, Double) in [(.playing, 280), (.paused, 300), (.playing, 0)] {
            adapter.publish(PlaybackSnapshot(state: state, currentEpisode: current, position: position, rate: 1.5), resolvedDuration: nil)
            #expect(adapter.id == identity)
            #expect(adapter.values?.episodeID == current.id)
            #expect(adapter.values?.elapsedTime == position)
            #expect(adapter.values?.defaultPlaybackRate == 1.5)
        }
        adapter.clear()
        #expect(adapter.id == identity)
        #expect(adapter.values == nil)
        #expect(adapter.availableCommands.isEmpty)
        adapter.publish(PlaybackSnapshot(state: .paused, currentEpisode: episode(id: "next", duration: 100)), resolvedDuration: nil)
        #expect(adapter.id == identity)
        #expect(adapter.values?.episodeID.rawValue == "next")
    }

    @Test
    func configuredSkipIntervalsRejectInvalidUpdates() {
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: ImmediateArtworkLoader())
        adapter.setSkipIntervals(backward: 45, forward: 60)
        adapter.setSkipIntervals(backward: .nan, forward: 15)
        adapter.setSkipIntervals(backward: 30, forward: 0)
        #expect(adapter.skipBackwardInterval == 45)
        #expect(adapter.skipForwardInterval == 60)
    }
}
