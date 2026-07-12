import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript search index")
struct TranscriptSearchIndexTests {
    @Test("Matches are case and diacritic insensitive")
    func matchesAreCaseAndDiacriticInsensitive() {
        let index = TranscriptSearchIndex(segments: [
            segment(id: 0, text: "Café culture in Vienna"),
            segment(id: 1, text: "Nothing relevant here"),
            segment(id: 2, text: "the CAFE debate")
        ])

        let result = index.result(for: "cafe")

        #expect(result.matchSegmentIDs == [0, 2])
        #expect(result.highlightRangesBySegmentID.keys.sorted() == [0, 2])
    }

    @Test("Blank queries match nothing")
    func blankQueriesMatchNothing() {
        let index = TranscriptSearchIndex(segments: [segment(id: 0, text: "Some text")])

        #expect(index.result(for: "").matchSegmentIDs.isEmpty)
        #expect(index.result(for: "   ").matchSegmentIDs.isEmpty)
    }

    @Test("Query whitespace is trimmed before matching")
    func queryWhitespaceIsTrimmedBeforeMatching() {
        let index = TranscriptSearchIndex(segments: [segment(id: 0, text: "trimmed query")])

        #expect(index.result(for: " query \n").matchSegmentIDs == [0])
    }

    @Test("Highlight ranges point into the original text")
    func highlightRangesPointIntoTheOriginalText() throws {
        let text = "the theme and the anthem"
        let index = TranscriptSearchIndex(segments: [segment(id: 7, text: text)])

        let result = index.result(for: "the")

        let ranges = try #require(result.highlightRangesBySegmentID[7])
        #expect(ranges.map { String(text[$0]) } == ["the", "the", "the", "the"])
    }

    @Test("Match IDs use segment identity, not array position")
    func matchIDsUseSegmentIdentity() {
        let index = TranscriptSearchIndex(segments: [
            segment(id: 40, text: "nothing"),
            segment(id: 41, text: "needle in a haystack")
        ])

        #expect(index.result(for: "needle").matchSegmentIDs == [41])
    }

    private func segment(id: Int, text: String) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: TimeInterval(id),
            end: TimeInterval(id + 1),
            text: text,
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
    }
}
