import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript karaoke layout")
struct TranscriptKaraokeLayoutTests {
    private let text = "Welcome to the show."
    private var wordedSegment: OpenCastTranscriptSegment {
        segment(words: [
            OpenCastTranscriptWord(start: 10.0, end: 10.4, text: "Welcome"),
            OpenCastTranscriptWord(start: 10.5, end: 10.6, text: "to"),
            OpenCastTranscriptWord(start: 10.7, end: 10.8, text: "the"),
            OpenCastTranscriptWord(start: 10.9, end: 11.5, text: "show.")
        ])
    }

    @Test("Wordless segments have no layout")
    func wordlessSegmentsHaveNoLayout() {
        #expect(TranscriptKaraokeLayout(segment: segment(words: nil)) == nil)
        #expect(TranscriptKaraokeLayout(segment: segment(words: [])) == nil)
    }

    @Test("A word that fails to scan drops the layout")
    func wordThatFailsToScanDropsTheLayout() {
        let mismatched = segment(words: [
            OpenCastTranscriptWord(start: 10.0, end: 10.4, text: "Welcome"),
            OpenCastTranscriptWord(start: 10.5, end: 10.6, text: "absent")
        ])

        #expect(TranscriptKaraokeLayout(segment: mismatched) == nil)
    }

    @Test("Spoken upper bound tracks word starts")
    func spokenUpperBoundTracksWordStarts() throws {
        let layout = try #require(TranscriptKaraokeLayout(segment: wordedSegment))

        #expect(layout.spokenUpperBound(at: 9.9) == text.startIndex)
        #expect(String(text[..<layout.spokenUpperBound(at: 10.0)]) == "Welcome")
        #expect(String(text[..<layout.spokenUpperBound(at: 10.55)]) == "Welcome to")
        #expect(String(text[..<layout.spokenUpperBound(at: 12.0)]) == "Welcome to the show.")
    }

    @Test("Word flip dates map starts through the interpolation")
    func wordFlipDatesMapStartsThroughTheInterpolation() throws {
        let layout = try #require(TranscriptKaraokeLayout(segment: wordedSegment))
        let baseDate = Date(timeIntervalSinceReferenceDate: 1000)
        let interpolator = TranscriptPositionInterpolator(
            basePosition: 10.0,
            baseDate: baseDate,
            rate: 2.0,
            isPlaying: true
        )

        let dates = layout.wordFlipDates(for: interpolator)

        #expect(dates.count == 4)
        #expect(dates[0] == baseDate)
        #expect(dates[1] == baseDate.addingTimeInterval(0.25))
        #expect(abs(dates[3].timeIntervalSince(baseDate) - 0.45) < 0.0001)
    }

    @Test("No flip dates while paused")
    func noFlipDatesWhilePaused() throws {
        let layout = try #require(TranscriptKaraokeLayout(segment: wordedSegment))
        let interpolator = TranscriptPositionInterpolator(
            basePosition: 10.0,
            baseDate: Date(timeIntervalSinceReferenceDate: 1000),
            rate: 1.0,
            isPlaying: false
        )

        #expect(layout.wordFlipDates(for: interpolator).isEmpty)
    }

    private func segment(words: [OpenCastTranscriptWord]?) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: 3,
            start: 10.0,
            end: 11.5,
            text: text,
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: words
        )
    }
}
