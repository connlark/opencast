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
        #expect(TranscriptKaraokeLayout(segment: segment(words: nil), handoff: .infinity) == nil)
        #expect(TranscriptKaraokeLayout(segment: segment(words: []), handoff: .infinity) == nil)
    }

    @Test("A word that fails to scan drops the layout")
    func wordThatFailsToScanDropsTheLayout() {
        let mismatched = segment(words: [
            OpenCastTranscriptWord(start: 10.0, end: 10.4, text: "Welcome"),
            OpenCastTranscriptWord(start: 10.5, end: 10.6, text: "absent")
        ])

        #expect(TranscriptKaraokeLayout(segment: mismatched, handoff: .infinity) == nil)
    }

    @Test("Display repair beyond the fallback threshold drops the layout")
    func displayRepairBeyondTheFallbackThresholdDropsTheLayout() {
        let wild = segment(words: [
            OpenCastTranscriptWord(start: 10.0, end: 10.4, text: "Welcome"),
            OpenCastTranscriptWord(start: 45.0, end: 46.0, text: "to"),
            OpenCastTranscriptWord(start: 46.0, end: 46.5, text: "the"),
            OpenCastTranscriptWord(start: 47.0, end: 47.5, text: "show.")
        ])

        #expect(TranscriptKaraokeLayout(segment: wild, handoff: 11.5) == nil)
    }

    @Test("Spoken upper bound tracks word starts")
    func spokenUpperBoundTracksWordStarts() throws {
        let layout = try #require(TranscriptKaraokeLayout(segment: wordedSegment, handoff: 11.5))

        #expect(layout.spokenUpperBound(at: 9.9) == text.startIndex)
        #expect(String(text[..<layout.spokenUpperBound(at: 10.0)]) == "Welcome")
        #expect(String(text[..<layout.spokenUpperBound(at: 10.55)]) == "Welcome to")
        #expect(String(text[..<layout.spokenUpperBound(at: 12.0)]) == "Welcome to the show.")
    }

    @Test("Every video-style word resolves at its own onset")
    func everyVideoStyleWordResolvesAtItsOwnOnset() throws {
        let segment = OpenCastTranscriptSegment(
            id: 7,
            start: 3612.34,
            end: 3615.91,
            text: "I also loved working at FX.",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: [
                OpenCastTranscriptWord(start: 3612.34, end: 3612.51, text: "I"),
                OpenCastTranscriptWord(start: 3612.51, end: 3612.9, text: "also"),
                OpenCastTranscriptWord(start: 3612.9, end: 3613.42, text: "loved"),
                OpenCastTranscriptWord(start: 3613.42, end: 3614.0, text: "working"),
                OpenCastTranscriptWord(start: 3614.0, end: 3614.37, text: "at"),
                OpenCastTranscriptWord(start: 3614.37, end: 3615.91, text: "FX.")
            ]
        )
        let layout = try #require(TranscriptKaraokeLayout(segment: segment, handoff: 3615.91))
        let prefixes = [
            "I", "I also", "I also loved", "I also loved working",
            "I also loved working at", "I also loved working at FX."
        ]

        for (index, word) in try #require(segment.words).enumerated() {
            #expect(
                String(segment.text[..<layout.spokenUpperBound(at: word.start)]) == prefixes[index]
            )
        }
    }

    @Test("A tail bunched at the handoff brightens before the line hands off")
    func tailBunchedAtTheHandoffBrightensBeforeTheLineHandsOff() throws {
        let segment = OpenCastTranscriptSegment(
            id: 9,
            start: 20.0,
            end: 21.4,
            text: "Stays dim for FX.",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: [
                OpenCastTranscriptWord(start: 20.0, end: 20.4, text: "Stays"),
                OpenCastTranscriptWord(start: 20.5, end: 20.9, text: "dim"),
                OpenCastTranscriptWord(start: 21.4, end: 21.4, text: "for"),
                OpenCastTranscriptWord(start: 21.4, end: 21.4, text: "FX.")
            ]
        )
        let layout = try #require(TranscriptKaraokeLayout(segment: segment, handoff: 21.4))
        let exposureStart = 21.4 - TranscriptKaraokeDisplayCues.minimumTerminalExposure

        #expect(String(segment.text[..<layout.spokenUpperBound(at: exposureStart)]) == segment.text)
        #expect(
            String(segment.text[..<layout.spokenUpperBound(at: exposureStart - 0.01)]) == "Stays dim"
        )
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
