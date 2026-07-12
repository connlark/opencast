import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript search matcher")
struct TranscriptSearchMatcherTests {
    @Test("Blank queries produce no ranges")
    func blankQueriesProduceNoRanges() {
        #expect(TranscriptSearchMatcher.matchRanges(of: "", in: "Some text").isEmpty)
        #expect(TranscriptSearchMatcher.matchRanges(of: " ", in: "Some text").isEmpty)
    }

    @Test("Match ranges are case and diacritic insensitive")
    func matchRangesAreCaseAndDiacriticInsensitive() {
        let text = "Café culture in Vienna"

        let ranges = TranscriptSearchMatcher.matchRanges(of: "CAFE", in: text)

        #expect(ranges.map { String(text[$0]) } == ["Café"])
    }

    @Test("Query whitespace is trimmed before matching")
    func queryWhitespaceIsTrimmedBeforeMatching() {
        let text = "trimmed query"

        let ranges = TranscriptSearchMatcher.matchRanges(of: " query \n", in: text)

        #expect(ranges.map { String(text[$0]) } == ["query"])
    }

    @Test("Match ranges cover every occurrence in a line")
    func matchRangesCoverEveryOccurrenceInALine() {
        let text = "the theme and the anthem"

        let ranges = TranscriptSearchMatcher.matchRanges(of: "the", in: text)

        #expect(ranges.map { String(text[$0]) } == ["the", "the", "the", "the"])
        #expect(ranges.first?.lowerBound == text.startIndex)
    }
}
