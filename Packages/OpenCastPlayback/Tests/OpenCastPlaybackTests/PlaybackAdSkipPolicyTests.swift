import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("Playback ad skip policy")
@MainActor
struct PlaybackAdSkipPolicyTests {
    @Test
    func acceptedTickEnteringZoneSkipsToZoneEnd() {
        var policy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])

        let command = policy.evaluate(
            previousPosition: 9.5,
            position: 10.2,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(command == .skip(to: 20, zoneID: 1))
    }

    @Test
    func emittedSkipDisarmsZoneUntilObservedOutside() {
        var policy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])

        let command = policy.evaluate(
            previousPosition: 9.5,
            position: 10.2,
            duration: 60,
            cause: .acceptedTick
        )
        let staleCommand = policy.evaluate(
            previousPosition: 20,
            position: 10.4,
            duration: 60,
            cause: .acceptedTick
        )
        let exitCommand = policy.evaluate(
            previousPosition: 10.4,
            position: 20,
            duration: 60,
            cause: .acceptedTick
        )
        let futureCommand = policy.evaluate(
            previousPosition: 9.9,
            position: 10.1,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(command == .skip(to: 20, zoneID: 1))
        #expect(staleCommand == nil)
        #expect(exitCommand == nil)
        #expect(futureCommand == .skip(to: 20, zoneID: 1))
    }

    @Test
    func subTickStraddleDoesNotSkip() {
        var policy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 10.4)])

        let command = policy.evaluate(
            previousPosition: 9.9,
            position: 10.5,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(command == nil)
    }

    @Test
    func scrubLandingDisarmsOnlyThatZoneUntilExitAndFuturePassReskips() {
        var policy = PlaybackAdSkipPolicy(zones: [
            zone(id: 1, start: 10, end: 20),
            zone(id: 2, start: 30, end: 40)
        ])

        let scrubCommand = policy.evaluate(
            previousPosition: nil,
            position: 12,
            duration: 90,
            cause: .seekLanding(.scrub)
        )
        #expect(scrubCommand == nil)

        let disarmedTick = policy.evaluate(
            previousPosition: 12,
            position: 13,
            duration: 90,
            cause: .acceptedTick
        )
        #expect(disarmedTick == nil)

        let laterZoneCommand = policy.evaluate(
            previousPosition: 29,
            position: 30.1,
            duration: 90,
            cause: .acceptedTick
        )
        #expect(laterZoneCommand == .skip(to: 40, zoneID: 2))

        let exitCommand = policy.evaluate(
            previousPosition: 19.8,
            position: 20.1,
            duration: 90,
            cause: .acceptedTick
        )
        #expect(exitCommand == nil)

        let futurePassCommand = policy.evaluate(
            previousPosition: 9.9,
            position: 10.1,
            duration: 90,
            cause: .acceptedTick
        )
        #expect(futurePassCommand == .skip(to: 20, zoneID: 1))
    }

    @Test
    func skipButtonAndRestoreLandingsSkipWhenInsideZone() {
        var skipPolicy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])
        var restorePolicy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])

        let skipButtonCommand = skipPolicy.evaluate(
            previousPosition: nil,
            position: 12,
            duration: 60,
            cause: .seekLanding(.skipButton)
        )
        let restoreCommand = restorePolicy.evaluate(
            previousPosition: nil,
            position: 12,
            duration: 60,
            cause: .seekLanding(.restore)
        )

        #expect(skipButtonCommand == .skip(to: 20, zoneID: 1))
        #expect(restoreCommand == .skip(to: 20, zoneID: 1))
    }

    @Test
    func autoSkipLandingOnlyChainEvaluates() {
        var policy = PlaybackAdSkipPolicy(zones: [
            zone(id: 1, start: 10, end: 20),
            zone(id: 2, start: 20.5, end: 30)
        ])

        let outsideCommand = policy.evaluate(
            previousPosition: nil,
            position: 20,
            duration: 60,
            cause: .seekLanding(.autoSkip)
        )
        let chainedCommand = policy.evaluate(
            previousPosition: nil,
            position: 20.6,
            duration: 60,
            cause: .seekLanding(.autoSkip)
        )

        #expect(outsideCommand == nil)
        #expect(chainedCommand == .skip(to: 30, zoneID: 2))
    }

    @Test
    func zoneAtZeroSkipsAtPlayStart() {
        var policy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 0, end: 7)])

        let command = policy.evaluate(
            previousPosition: -Double.ulpOfOne,
            position: 0,
            duration: 60,
            cause: .playStart
        )

        #expect(command == .skip(to: 7, zoneID: 1))
    }

    @Test
    func endClampedZoneSeeksToDuration() {
        var policy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 55, end: 70)])

        let command = policy.evaluate(
            previousPosition: 54,
            position: 55,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(command == .skip(to: 60, zoneID: 1))
    }

    @Test
    func adjacentZonesNormalizeToSingleSkip() {
        var policy = PlaybackAdSkipPolicy(zones: [
            zone(id: 1, start: 10, end: 15),
            zone(id: 2, start: 15, end: 22)
        ])

        let command = policy.evaluate(
            previousPosition: 9,
            position: 10,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(policy.zones == [zone(id: 1, start: 10, end: 22)])
        #expect(command == .skip(to: 22, zoneID: 1))
    }

    @Test
    func disabledFlagIsInert() {
        var policy = PlaybackAdSkipPolicy(
            zones: [zone(id: 1, start: 10, end: 20)],
            isEnabled: false
        )

        let command = policy.evaluate(
            previousPosition: 9,
            position: 10,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(command == nil)
    }

    @Test
    func zoneReplacementResetsDisarmState() {
        var policy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])

        _ = policy.evaluate(
            previousPosition: nil,
            position: 12,
            duration: 60,
            cause: .seekLanding(.scrub)
        )
        policy.setZones([zone(id: 1, start: 10, end: 20)])
        let command = policy.evaluate(
            previousPosition: 9,
            position: 10,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(command == .skip(to: 20, zoneID: 1))
    }

    @Test
    func zeroZonesPreserveNoOpBehavior() {
        var policy = PlaybackAdSkipPolicy()

        let tickCommand = policy.evaluate(
            previousPosition: 1,
            position: 2,
            duration: 60,
            cause: .acceptedTick
        )
        let seekCommand = policy.evaluate(
            previousPosition: nil,
            position: 2,
            duration: 60,
            cause: .seekLanding(.skipButton)
        )

        #expect(tickCommand == nil)
        #expect(seekCommand == nil)
    }

    @Test
    func logicUsesTimelinePositionsOnly() {
        var normalRatePolicy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])
        var fastRatePolicy = PlaybackAdSkipPolicy(zones: [zone(id: 1, start: 10, end: 20)])

        let normalCommand = normalRatePolicy.evaluate(
            previousPosition: 9.9,
            position: 10.1,
            duration: 60,
            cause: .acceptedTick
        )
        let fastCommand = fastRatePolicy.evaluate(
            previousPosition: 9.9,
            position: 10.1,
            duration: 60,
            cause: .acceptedTick
        )

        #expect(normalCommand == fastCommand)
    }

    private func zone(id: Int, start: TimeInterval, end: TimeInterval) -> PlaybackSkipZone {
        PlaybackSkipZone(id: id, startTime: start, endTime: end)
    }
}
