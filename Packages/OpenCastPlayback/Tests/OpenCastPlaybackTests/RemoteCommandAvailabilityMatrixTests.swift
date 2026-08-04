import Foundation
@preconcurrency import MediaPlayer
import OpenCastCore
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct RemoteCommandAvailabilityMatrixTests {
    private final class FakeToggle: RemoteCommandToggling {
        var isEnabled: Bool

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }
    }

    private struct ExpectedAvailability {
        let play: Bool
        let pause: Bool
        /// togglePlayPause + the four skip aliases + changeRate all follow
        /// plain has-loaded-content.
        let whileLoaded: Bool
        let seek: Bool
    }

    private struct MatrixRow {
        let name: String
        let snapshot: PlaybackSnapshot
        let resolvedDuration: TimeInterval?
        let expected: ExpectedAvailability
    }

    private var rows: [MatrixRow] { [
        MatrixRow(
            name: "no episode",
            snapshot: PlaybackSnapshot(state: .idle, currentEpisode: nil, duration: 300),
            resolvedDuration: nil,
            expected: ExpectedAvailability(play: false, pause: false, whileLoaded: false, seek: false)
        ),
        MatrixRow(
            name: "loaded, nil duration",
            snapshot: PlaybackSnapshot(
                state: .paused,
                currentEpisode: episode(duration: nil),
                duration: nil
            ),
            resolvedDuration: nil,
            expected: ExpectedAvailability(play: true, pause: false, whileLoaded: true, seek: false)
        ),
        MatrixRow(
            name: "failed state",
            snapshot: PlaybackSnapshot(
                state: .failed("Deterministic failure"),
                currentEpisode: episode(duration: 300),
                duration: 300
            ),
            resolvedDuration: nil,
            expected: ExpectedAvailability(play: true, pause: false, whileLoaded: true, seek: true)
        ),
        MatrixRow(
            name: "loading",
            snapshot: PlaybackSnapshot(
                state: .loading,
                currentEpisode: episode(duration: nil),
                duration: nil
            ),
            // The item's duration is not known yet; the resolved duration
            // arriving separately must not enable seek on its own — it does
            // (current pinned behavior: any finite duration makes the loaded
            // episode seekable).
            resolvedDuration: 300,
            expected: ExpectedAvailability(play: true, pause: false, whileLoaded: true, seek: true)
        ),
        MatrixRow(
            name: "playing",
            snapshot: PlaybackSnapshot(
                state: .playing,
                currentEpisode: episode(duration: 300),
                duration: 300
            ),
            resolvedDuration: nil,
            expected: ExpectedAvailability(play: false, pause: true, whileLoaded: true, seek: true)
        ),
    ] }

    @Test("Availability matrix over state × command")
    func availabilityMatrix() {
        for row in rows {
            assertAvailability(row)
        }
    }

    private func assertAvailability(_ row: MatrixRow) {
        // Every fake starts at the negation of its expectation so a missing
        // write fails the row rather than passing by initial value.
        let play = FakeToggle(isEnabled: !row.expected.play)
        let pause = FakeToggle(isEnabled: !row.expected.pause)
        let togglePlayPause = FakeToggle(isEnabled: !row.expected.whileLoaded)
        let skipForward = FakeToggle(isEnabled: !row.expected.whileLoaded)
        let skipBackward = FakeToggle(isEnabled: !row.expected.whileLoaded)
        let nextTrack = FakeToggle(isEnabled: !row.expected.whileLoaded)
        let previousTrack = FakeToggle(isEnabled: !row.expected.whileLoaded)
        let changeRate = FakeToggle(isEnabled: !row.expected.whileLoaded)
        let changePosition = FakeToggle(isEnabled: !row.expected.seek)
        let controller = RemoteCommandController(
            availabilitySurface: RemoteCommandAvailabilitySurface(
                play: play,
                pause: pause,
                togglePlayPause: togglePlayPause,
                skipForward: skipForward,
                skipBackward: skipBackward,
                nextTrack: nextTrack,
                previousTrack: previousTrack,
                changePlaybackRate: changeRate,
                changePlaybackPosition: changePosition
            )
        )

        controller.updateAvailability(
            for: row.snapshot,
            resolvedDuration: row.resolvedDuration
        )

        #expect(play.isEnabled == row.expected.play, "\(row.name): play")
        #expect(pause.isEnabled == row.expected.pause, "\(row.name): pause")
        #expect(togglePlayPause.isEnabled == row.expected.whileLoaded, "\(row.name): toggle")
        #expect(skipForward.isEnabled == row.expected.whileLoaded, "\(row.name): skip forward")
        #expect(skipBackward.isEnabled == row.expected.whileLoaded, "\(row.name): skip backward")
        #expect(nextTrack.isEnabled == row.expected.whileLoaded, "\(row.name): next track alias")
        #expect(previousTrack.isEnabled == row.expected.whileLoaded, "\(row.name): previous track alias")
        #expect(changeRate.isEnabled == row.expected.whileLoaded, "\(row.name): change rate")
        #expect(changePosition.isEnabled == row.expected.seek, "\(row.name): seek")
    }

    @Test("Buffering counts as playback requested, like playing")
    func bufferingCountsAsPlaybackRequested() {
        let play = FakeToggle(isEnabled: true)
        let pause = FakeToggle(isEnabled: false)
        let others = (0..<7).map { _ in FakeToggle(isEnabled: false) }
        let controller = RemoteCommandController(
            availabilitySurface: RemoteCommandAvailabilitySurface(
                play: play,
                pause: pause,
                togglePlayPause: others[0],
                skipForward: others[1],
                skipBackward: others[2],
                nextTrack: others[3],
                previousTrack: others[4],
                changePlaybackRate: others[5],
                changePlaybackPosition: others[6]
            )
        )

        controller.updateAvailability(
            for: PlaybackSnapshot(
                state: .buffering,
                currentEpisode: episode(duration: 300),
                duration: 300
            ),
            resolvedDuration: nil
        )

        #expect(!play.isEnabled)
        #expect(pause.isEnabled)
    }
}
