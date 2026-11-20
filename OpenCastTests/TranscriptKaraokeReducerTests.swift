import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript karaoke reducer")
struct TranscriptKaraokeReducerTests {
    private let timeline = TranscriptTimeline(segments: [
        OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 4,
            text: "one two three four",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: [
                OpenCastTranscriptWord(start: 0, end: 0.8, text: "one"),
                OpenCastTranscriptWord(start: 1, end: 1.8, text: "two"),
                OpenCastTranscriptWord(start: 2, end: 2.8, text: "three"),
                OpenCastTranscriptWord(start: 3, end: 3.8, text: "four")
            ]
        ),
        OpenCastTranscriptSegment(
            id: 1,
            start: 4,
            end: 4.4,
            text: "so brief",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: [
                OpenCastTranscriptWord(start: 4.0, end: 4.15, text: "so"),
                OpenCastTranscriptWord(start: 4.2, end: 4.4, text: "brief")
            ]
        ),
        OpenCastTranscriptSegment(
            id: 2,
            start: 4.4,
            end: 10,
            text: "closing thoughts here",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: [
                OpenCastTranscriptWord(start: 4.4, end: 5.5, text: "closing"),
                OpenCastTranscriptWord(start: 6, end: 7, text: "thoughts"),
                OpenCastTranscriptWord(start: 8, end: 9, text: "here")
            ]
        )
    ])

    @Test("A coalesced jump resolves the landing segment with no intermediates")
    func coalescedJumpResolvesTheLandingSegmentWithNoIntermediates() throws {
        let landingLayout = try layout(at: 2)

        let jumped = TranscriptKaraokeReducer.frame(at: 6.5, timeline: timeline, activeLayout: landingLayout)

        #expect(jumped.segmentID == 2)
        #expect(spoken(jumped, in: 2) == "closing thoughts")
        #expect(jumped == TranscriptKaraokeReducer.frame(at: 6.5, timeline: timeline, activeLayout: landingLayout))
    }

    @Test("A backward seek shrinks the spoken prefix")
    func backwardSeekShrinksTheSpokenPrefix() throws {
        let layout = try layout(at: 0)

        let late = TranscriptKaraokeReducer.frame(at: 3.5, timeline: timeline, activeLayout: layout)
        let early = TranscriptKaraokeReducer.frame(at: 1.2, timeline: timeline, activeLayout: layout)

        #expect(spoken(late, in: 0) == "one two three four")
        #expect(spoken(early, in: 0) == "one two")
    }

    @Test("Positions before the first segment resolve to nothing")
    func positionsBeforeTheFirstSegmentResolveToNothing() {
        let frame = TranscriptKaraokeReducer.frame(at: -1, timeline: timeline, activeLayout: nil)

        #expect(frame.segmentID == nil)
        #expect(frame.spokenUpperBound == nil)
    }

    @Test("A layout for another segment yields no spoken bound")
    func layoutForAnotherSegmentYieldsNoSpokenBound() throws {
        let staleLayout = try layout(at: 0)

        let frame = TranscriptKaraokeReducer.frame(at: 6.5, timeline: timeline, activeLayout: staleLayout)

        #expect(frame.segmentID == 2)
        #expect(frame.spokenUpperBound == nil)
    }

    private func layout(at index: Int) throws -> TranscriptKaraokeLayout {
        try #require(TranscriptKaraokeLayout(
            segment: timeline.segments[index],
            handoff: timeline.handoff(afterSegmentAt: index)
        ))
    }

    private func spoken(_ frame: TranscriptKaraokeReducer.Frame, in segmentIndex: Int) -> String? {
        guard let bound = frame.spokenUpperBound else {
            return nil
        }
        let text = timeline.segments[segmentIndex].text
        return String(text[..<bound])
    }
}
