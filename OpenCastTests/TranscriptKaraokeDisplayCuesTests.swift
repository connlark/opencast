import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript karaoke display cues")
struct TranscriptKaraokeDisplayCuesTests {
    @Test("Clean words pass through with no repairs")
    func cleanWordsPassThroughWithNoRepairs() throws {
        let segment = segment(start: 0, end: 4, words: [
            OpenCastTranscriptWord(start: 0, end: 0.6, text: "Welcome"),
            OpenCastTranscriptWord(start: 0.7, end: 0.9, text: "to"),
            OpenCastTranscriptWord(start: 1.0, end: 1.1, text: "a"),
            OpenCastTranscriptWord(start: 1.2, end: 2.4, text: "deterministic"),
            OpenCastTranscriptWord(start: 2.6, end: 3.6, text: "transcript.")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 4))

        #expect(repaired.words.map(\.start) == [0, 0.7, 1.0, 1.2, 2.6])
        #expect(repaired.repairs.isEmpty)
    }

    @Test("Non-finite words are dropped and recorded")
    func nonFiniteWordsAreDroppedAndRecorded() throws {
        let segment = segment(start: 0, end: 4, words: [
            OpenCastTranscriptWord(start: 0, end: 0.5, text: "one"),
            OpenCastTranscriptWord(start: .nan, end: 1.2, text: "two"),
            OpenCastTranscriptWord(start: 1.4, end: 1.8, text: "three"),
            OpenCastTranscriptWord(start: 2.0, end: 2.4, text: "four")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 4))

        #expect(repaired.words.map(\.text) == ["one", "three", "four"])
        #expect(repaired.repairs == [.droppedNonFinite])
    }

    @Test("Dropping more than a quarter of the words falls back")
    func droppingMoreThanAQuarterOfTheWordsFallsBack() {
        let segment = segment(start: 0, end: 4, words: [
            OpenCastTranscriptWord(start: 0, end: 0.5, text: "one"),
            OpenCastTranscriptWord(start: .nan, end: 1.2, text: "two")
        ])

        #expect(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 4) == nil)
    }

    @Test("Onsets before the segment start are clamped")
    func onsetsBeforeTheSegmentStartAreClamped() throws {
        let segment = segment(start: 10, end: 14, words: [
            OpenCastTranscriptWord(start: 9.4, end: 10.5, text: "early"),
            OpenCastTranscriptWord(start: 11, end: 12, text: "onward")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 14))

        #expect(repaired.words.map(\.start) == [10, 11])
        #expect(repaired.repairs == [.clampedToSegment])
    }

    @Test("A legacy word past the segment end lands inside the display interval")
    func legacyWordPastTheSegmentEndLandsInsideTheDisplayInterval() throws {
        let segment = segment(start: 0, end: 2, words: [
            OpenCastTranscriptWord(start: 0, end: 1, text: "First"),
            OpenCastTranscriptWord(start: 2.6, end: 2.8, text: "tail.")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 2))

        #expect(repaired.words.map(\.start) == [0, 2 - TranscriptKaraokeDisplayCues.minimumTerminalExposure])
        #expect(repaired.repairs == [.clampedToHandoff, .terminalGroupShifted])
    }

    @Test("Decreasing onsets become nondecreasing and group as equals")
    func decreasingOnsetsBecomeNondecreasingAndGroupAsEquals() throws {
        let segment = segment(start: 0, end: 4, words: [
            OpenCastTranscriptWord(start: 1.0, end: 1.5, text: "one"),
            OpenCastTranscriptWord(start: 0.5, end: 0.9, text: "two"),
            OpenCastTranscriptWord(start: 2.0, end: 2.4, text: "three")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 4))

        #expect(repaired.words.map(\.start) == [1.0, 1.0, 2.0])
        #expect(repaired.repairs == [.nondecreasingEnforced])
    }

    @Test("A tail bunched at the handoff shifts back as one group")
    func tailBunchedAtTheHandoffShiftsBackAsOneGroup() throws {
        let segment = segment(start: 20.0, end: 21.4, words: [
            OpenCastTranscriptWord(start: 20.0, end: 20.4, text: "Stays"),
            OpenCastTranscriptWord(start: 20.5, end: 20.9, text: "dim"),
            OpenCastTranscriptWord(start: 21.4, end: 21.4, text: "for"),
            OpenCastTranscriptWord(start: 21.4, end: 21.4, text: "FX.")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 21.4))

        let shifted = 21.4 - TranscriptKaraokeDisplayCues.minimumTerminalExposure
        #expect(repaired.words.map(\.start) == [20.0, 20.5, shifted, shifted])
        #expect(repaired.repairs == [.clampedToHandoff, .clampedToHandoff, .terminalGroupShifted])
    }

    @Test("A crowded tail merges into the previous group before shifting")
    func crowdedTailMergesIntoThePreviousGroupBeforeShifting() throws {
        let segment = segment(start: 0, end: 10, words: [
            OpenCastTranscriptWord(start: 1, end: 2, text: "one"),
            OpenCastTranscriptWord(start: 9.95, end: 10, text: "two"),
            OpenCastTranscriptWord(start: 10, end: 10, text: "three")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 10))

        let shifted = 10 - TranscriptKaraokeDisplayCues.minimumTerminalExposure
        #expect(repaired.words.map(\.start) == [1, shifted, shifted])
        #expect(repaired.repairs == [.clampedToHandoff, .terminalGroupMerged, .terminalGroupShifted])
    }

    @Test("A line shorter than the minimum exposure collapses to one group")
    func lineShorterThanTheMinimumExposureCollapsesToOneGroup() throws {
        let segment = segment(start: 5, end: 5.05, words: [
            OpenCastTranscriptWord(start: 5, end: 5.02, text: "so"),
            OpenCastTranscriptWord(start: 5.04, end: 5.05, text: "brief")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 5.05))

        #expect(repaired.words.map(\.start) == [5, 5])
        #expect(repaired.repairs.contains(.terminalGroupMerged))
    }

    @Test("The last segment keeps end-bunched onsets untouched")
    func lastSegmentKeepsEndBunchedOnsetsUntouched() throws {
        let segment = segment(start: 0, end: 3, words: [
            OpenCastTranscriptWord(start: 0, end: 1, text: "closing"),
            OpenCastTranscriptWord(start: 3, end: 3, text: "words")
        ])

        let repaired = try #require(TranscriptKaraokeDisplayCues.repairedWords(
            for: segment,
            handoff: .infinity
        ))

        #expect(repaired.words.map(\.start) == [0, 3])
        #expect(repaired.repairs.isEmpty)
    }

    @Test("Extreme onset corrections fall back to line-level")
    func extremeOnsetCorrectionsFallBackToLineLevel() {
        let segment = segment(start: 0, end: 10, words: [
            OpenCastTranscriptWord(start: 0, end: 1, text: "fine"),
            OpenCastTranscriptWord(start: 40, end: 41, text: "wild")
        ])

        #expect(TranscriptKaraokeDisplayCues.repairedWords(for: segment, handoff: 10) == nil)
    }

    @Test("Wordless segments have no cues")
    func wordlessSegmentsHaveNoCues() {
        #expect(TranscriptKaraokeDisplayCues.repairedWords(
            for: segment(start: 0, end: 4, words: nil),
            handoff: 4
        ) == nil)
        #expect(TranscriptKaraokeDisplayCues.repairedWords(
            for: segment(start: 0, end: 4, words: []),
            handoff: 4
        ) == nil)
    }

    private func segment(
        start: TimeInterval,
        end: TimeInterval,
        words: [OpenCastTranscriptWord]?
    ) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: 1,
            start: start,
            end: end,
            text: (words ?? []).map(\.text).joined(separator: " "),
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: words
        )
    }
}
