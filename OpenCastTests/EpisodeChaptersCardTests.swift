import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode chapters card")
struct EpisodeChaptersCardTests {
    @Test("Start times outside the timestamp range clamp to it instead of trapping", arguments: zip(
        [.nan, -1, -.infinity, .infinity, 1_000_000_001] as [TimeInterval],
        [0, 0, 0, 1_000_000_000, 1_000_000_000] as [TimeInterval]
    ))
    func clampsStartTimes(startTime: TimeInterval, clamped: TimeInterval) {
        #expect(EpisodeChaptersCard.startTimeText(startTime) == EpisodeChaptersCard.startTimeText(clamped))
    }
}
