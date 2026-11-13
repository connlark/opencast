import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode chapters card")
struct EpisodeChaptersCardTests {
    @Test("Start times under an hour show minutes, and from an hour on show hours")
    func startTimePatternFollowsTheHour() {
        #expect(EpisodeChaptersCard.startTimeText(3_599).split(separator: ":").count == 2)
        #expect(EpisodeChaptersCard.startTimeText(3_600).split(separator: ":").count == 3)
    }

    @Test("Start times past the timestamp bound clamp to it instead of trapping")
    func clampsStartTimesPastTheBound() {
        let atBound = EpisodeChaptersCard.startTimeText(PublisherChaptersDocumentDecoder.maximumTimestamp)

        for startTime in [1e300, .infinity, 1e15, 1_000_000_001] as [TimeInterval] {
            #expect(EpisodeChaptersCard.startTimeText(startTime) == atBound)
        }
        #expect(EpisodeChaptersCard.startTimeText(999_999_999) != atBound)
    }

    @Test("Negative and NaN start times read as the episode start")
    func negativeAndNaNStartTimesReadAsZero() {
        let zero = EpisodeChaptersCard.startTimeText(0)

        for startTime in [-1, -.infinity, .nan] as [TimeInterval] {
            #expect(EpisodeChaptersCard.startTimeText(startTime) == zero)
        }
    }
}
