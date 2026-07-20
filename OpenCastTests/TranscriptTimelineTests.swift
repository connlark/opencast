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

    @Test("Active word is the last one starting at or before the time")
    func activeWordIsTheLastOneStartingAtOrBeforeTheTime() {
        let timeline = TranscriptTimeline(segments: [
            segment(id: 0, start: 0, end: 6, words: [
                OpenCastTranscriptWord(start: 0, end: 1, text: "one"),
                OpenCastTranscriptWord(start: 2, end: 3, text: "two"),
                OpenCastTranscriptWord(start: 4, end: 5, text: "three")
            ])
        ])

        #expect(timeline.wordIndex(in: 0, at: 0) == 0)
        #expect(timeline.wordIndex(in: 0, at: 1.9) == 0)
        #expect(timeline.wordIndex(in: 0, at: 2) == 1)
        #expect(timeline.wordIndex(in: 0, at: 6) == 2)
    }

    @Test("Word lookup is nil for line-level segments and invalid indices")
    func wordLookupIsNilForLineLevelSegmentsAndInvalidIndices() {
        let timeline = TranscriptTimeline(segments: [
            segment(id: 0, start: 0, end: 6),
            segment(id: 1, start: 6, end: 9, words: [
                OpenCastTranscriptWord(start: 7, end: 8, text: "late")
            ])
        ])

        #expect(timeline.wordIndex(in: 0, at: 3) == nil)
        #expect(timeline.wordIndex(in: 1, at: 6.5) == nil)
        #expect(timeline.wordIndex(in: 5, at: 3) == nil)
    }

    private func segment(
        id: Int,
        start: TimeInterval,
        end: TimeInterval,
        words: [OpenCastTranscriptWord]? = nil
    ) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: "segment \(id)",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: words
        )
    }
}
