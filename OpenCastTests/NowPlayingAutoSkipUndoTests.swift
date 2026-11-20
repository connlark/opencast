import Foundation
import OpenCastPlayback
import Testing
@testable import OpenCast

@Suite("Now Playing auto-skip pill undo")
struct NowPlayingAutoSkipUndoTests {
    @Test(
        "Undo lands half a second inside the skipped zone, never past a tiny zone's midpoint",
        arguments: [
            (start: 1262.0, end: 1384.0, target: 1262.5),
            (start: 10.0, end: 10.6, target: 10.3)
        ]
    )
    func seekTarget(start: TimeInterval, end: TimeInterval, target: TimeInterval) {
        let zones = [
            PlaybackSkipZone(id: 1, startTime: 51, endTime: 141),
            PlaybackSkipZone(id: 2, startTime: start, endTime: end)
        ]
        #expect(NowPlayingAutoSkipUndo.seekTarget(
            for: PlaybackAutoSkipEvent(zoneID: 2, sequence: 1),
            zones: zones
        ) == target)
    }

    @Test
    func undoSeekIntentLandsAsScrubSoTheZonePlaysThroughOnceAndRearms() {
        #expect(NowPlayingAutoSkipUndo.seekIntent == .scrub)

        var policy = PlaybackAdSkipPolicy(zones: [
            PlaybackSkipZone(id: 1, startTime: 51, endTime: 141),
            PlaybackSkipZone(id: 2, startTime: 1262, endTime: 1384)
        ])
        let landing = policy.evaluate(
            previousPosition: 1384,
            position: 1262.5,
            duration: 4080,
            cause: .seekLanding(NowPlayingAutoSkipUndo.seekIntent)
        )
        #expect(landing == nil)

        let playThroughTick = policy.evaluate(
            previousPosition: 1262,
            position: 1300,
            duration: 4080,
            cause: .acceptedTick
        )
        #expect(playThroughTick == nil)

        let exitTick = policy.evaluate(
            previousPosition: 1300,
            position: 1385,
            duration: 4080,
            cause: .acceptedTick
        )
        #expect(exitTick == nil)

        let reentryTick = policy.evaluate(
            previousPosition: 1261,
            position: 1263,
            duration: 4080,
            cause: .acceptedTick
        )
        #expect(reentryTick == .skip(to: 1384, zoneID: 2))
    }
}
