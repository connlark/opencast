import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript timeline")
struct TranscriptTimelineTests {
    @Test("Active segment is the last one starting at or before the time")
    func activeSegmentIsTheLastOneStartingAtOrBeforeTheTime() {
        let timeline = TranscriptTimeline(segments: [
            segment(id: 0, start: 0, end: 4),
            segment(id: 1, start: 4, end: 9),
            segment(id: 2, start: 12, end: 20)
        ])

        #expect(timeline.segmentIndex(at: 0) == 0)
        #expect(timeline.segmentIndex(at: 3.9) == 0)
        #expect(timeline.segmentIndex(at: 4) == 1)
        #expect(timeline.segmentIndex(at: 10.5) == 1)
        #expect(timeline.segmentIndex(at: 12) == 2)
        #expect(timeline.segmentIndex(at: 500) == 2)
    }

    @Test("No segment is active before the first start or in an empty timeline")
    func noSegmentIsActiveBeforeTheFirstStartOrInAnEmptyTimeline() {
        let timeline = TranscriptTimeline(segments: [segment(id: 0, start: 5, end: 8)])

        #expect(timeline.segmentIndex(at: 4.9) == nil)
        #expect(TranscriptTimeline().segmentIndex(at: 10) == nil)
    }

    @Test("Handoff is the next segment's start, or infinity for the last")
    func handoffIsTheNextSegmentsStartOrInfinityForTheLast() {
        let timeline = TranscriptTimeline(segments: [
            segment(id: 0, start: 0, end: 4),
            segment(id: 1, start: 4, end: 9),
            segment(id: 2, start: 12, end: 20)
        ])

        #expect(timeline.handoff(afterSegmentAt: 0) == 4)
        #expect(timeline.handoff(afterSegmentAt: 1) == 12)
        #expect(timeline.handoff(afterSegmentAt: 2) == .infinity)
    }

    private func segment(id: Int, start: TimeInterval, end: TimeInterval) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: "segment \(id)",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
    }
}
