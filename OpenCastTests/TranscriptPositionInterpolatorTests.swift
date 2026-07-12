import Foundation
import Testing
@testable import OpenCast

@Suite("Transcript position interpolator")
struct TranscriptPositionInterpolatorTests {
    @Test("Playing positions advance with elapsed time and rate")
    func playingPositionsAdvanceWithElapsedTimeAndRate() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let interpolator = TranscriptPositionInterpolator(
            basePosition: 120,
            baseDate: baseDate,
            rate: 1.5,
            isPlaying: true
        )

        #expect(interpolator.estimatedTime(at: baseDate) == 120)
        #expect(interpolator.estimatedTime(at: baseDate.addingTimeInterval(2)) == 123)
    }

    @Test("Paused positions do not advance")
    func pausedPositionsDoNotAdvance() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let interpolator = TranscriptPositionInterpolator(
            basePosition: 120,
            baseDate: baseDate,
            rate: 1,
            isPlaying: false
        )

        #expect(interpolator.estimatedTime(at: baseDate.addingTimeInterval(10)) == 120)
    }

    @Test("Clock skew before the base date never rewinds the position")
    func clockSkewBeforeTheBaseDateNeverRewindsThePosition() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let interpolator = TranscriptPositionInterpolator(
            basePosition: 120,
            baseDate: baseDate,
            rate: 2,
            isPlaying: true
        )

        #expect(interpolator.estimatedTime(at: baseDate.addingTimeInterval(-5)) == 120)
    }

    @Test("Non-positive rates hold the base position")
    func nonPositiveRatesHoldTheBasePosition() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let interpolator = TranscriptPositionInterpolator(
            basePosition: 120,
            baseDate: baseDate,
            rate: 0,
            isPlaying: true
        )

        #expect(interpolator.estimatedTime(at: baseDate.addingTimeInterval(4)) == 120)
    }
}
