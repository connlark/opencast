import Testing
@testable import OpenCastPlayback

@Suite("Playback rate steps")
struct PlaybackRateStepsTests {
    @Test("The canonical steps are the phone's Speed sheet, slowest first")
    func canonicalSteps() {
        #expect(PlaybackRateSteps.steps == [0.75, 1, 1.25, 1.5, 1.75, 2])
        #expect(PlaybackRateSteps.steps == PlaybackRateSteps.steps.sorted())
    }

    @Test("Every step advances to the following step")
    func advancesThroughSteps() {
        #expect(PlaybackRateSteps.next(after: 0.75) == 1)
        #expect(PlaybackRateSteps.next(after: 1) == 1.25)
        #expect(PlaybackRateSteps.next(after: 1.25) == 1.5)
        #expect(PlaybackRateSteps.next(after: 1.5) == 1.75)
        #expect(PlaybackRateSteps.next(after: 1.75) == 2)
    }

    @Test("The fastest step wraps back to the slowest")
    func wrapsPastTheFastestStep() {
        #expect(PlaybackRateSteps.next(after: 2) == 0.75)
        // The clamp accepts up to 3.0, which is past every step.
        #expect(PlaybackRateSteps.next(after: 3) == 0.75)
    }

    @Test("Rates between steps advance to the next step above them")
    func advancesFromNonSteps() {
        #expect(PlaybackRateSteps.next(after: 0.5) == 0.75)
        #expect(PlaybackRateSteps.next(after: 1.6) == 1.75)
        #expect(PlaybackRateSteps.next(after: 1.9) == 2)
    }

    @Test("A step cycles through every other step before repeating")
    func cyclesThroughAllSteps() {
        var visited: [Float] = []
        var rate = PlaybackRateSteps.steps[0]
        for _ in PlaybackRateSteps.steps {
            visited.append(rate)
            rate = PlaybackRateSteps.next(after: rate)
        }

        #expect(visited == PlaybackRateSteps.steps)
        #expect(rate == PlaybackRateSteps.steps[0])
    }
}
