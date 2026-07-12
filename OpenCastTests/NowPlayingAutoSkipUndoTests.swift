import Foundation
import OpenCastPlayback
import Testing
@testable import OpenCast

@Suite("Now Playing auto-skip pill undo")
struct NowPlayingAutoSkipUndoTests {
    private let zones = [
        PlaybackSkipZone(id: 1, startTime: 51, endTime: 141),
        PlaybackSkipZone(id: 2, startTime: 1262, endTime: 1384)
    ]

    @Test
    func seekTargetLandsJustInsideTheSkippedZoneStart() {
        // Exactly zone.startTime can land a frame before the zone and miss
        // the .scrub disarm (measured live re-skip); the target sits half a
        // second inside.
        let target = NowPlayingAutoSkipUndo.seekTarget(
            for: PlaybackAutoSkipEvent(zoneID: 2, sequence: 1),
            zones: zones
        )
        #expect(target == 1262.5)
    }

    @Test
    func seekTargetNeverPassesTheMidpointOfTinyZones() {
        let tinyZone = [PlaybackSkipZone(id: 7, startTime: 10, endTime: 10.6)]
        let target = NowPlayingAutoSkipUndo.seekTarget(
            for: PlaybackAutoSkipEvent(zoneID: 7, sequence: 1),
            zones: tinyZone
        )
        #expect(target == 10.3)
    }

    @Test
    func missingEventOrUnknownZoneProducesNoSeek() {
        #expect(NowPlayingAutoSkipUndo.seekTarget(for: nil, zones: zones) == nil)
        #expect(NowPlayingAutoSkipUndo.seekTarget(
            for: PlaybackAutoSkipEvent(zoneID: 99, sequence: 1),
            zones: zones
        ) == nil)
        #expect(NowPlayingAutoSkipUndo.seekTarget(
            for: PlaybackAutoSkipEvent(zoneID: 1, sequence: 1),
            zones: []
        ) == nil)
    }

    @Test
    func undoSeekIntentLandsAsScrubSoTheZonePlaysThroughOnceAndRearms() {
        // The pill undo relies on the existing `.scrub`-landing disarm: the
        // policy must not re-skip on the landing, must stay quiet while the
        // zone plays through, and must re-arm after exit.
        #expect(NowPlayingAutoSkipUndo.seekIntent == .scrub)

        var policy = PlaybackAdSkipPolicy(zones: zones)
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

        // Exit the zone, then re-enter: the zone must re-arm and skip again.
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
