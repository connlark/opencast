import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript segment normalizer")
struct OpenCastTranscriptSegmentNormalizerTests {
    @Test("Normalization reindexes segments and keeps their words")
    func normalizationReindexesSegmentsAndKeepsTheirWords() {
        let segments = OpenCastTranscriptSegmentNormalizer.normalized([
            segment(id: 7, start: 4, end: 6, text: "second", words: [word(4, 6, "second")]),
            segment(id: 3, start: 0, end: 2, text: "first", words: [word(0, 2, "first")])
        ])

        #expect(segments.map(\.id) == [0, 1])
        #expect(segments.map(\.words) == [[word(0, 2, "first")], [word(4, 6, "second")]])
    }

    @Test("Wordless segments stay wordless through normalization")
    func wordlessSegmentsStayWordlessThroughNormalization() {
        let segments = OpenCastTranscriptSegmentNormalizer.normalized([
            segment(id: 0, start: 0, end: 2, text: "no words")
        ])

        #expect(segments.count == 1)
        #expect(segments.first?.words == nil)
    }

    @Test("Words clamp into segment bounds")
    func wordsClampIntoSegmentBounds() {
        let words = OpenCastTranscriptSegmentNormalizer.normalizedWords(
            [word(-1, 0.5, "early"), word(1, 3, "late")],
            within: 0, 2
        )

        #expect(words == [word(0, 0.5, "early"), word(1, 2, "late")])
    }

    @Test("Overlapping words become monotonic")
    func overlappingWordsBecomeMonotonic() {
        let words = OpenCastTranscriptSegmentNormalizer.normalizedWords(
            [word(0, 1.5, "one"), word(1, 2, "two"), word(1.2, 1.4, "three")],
            within: 0, 3
        )

        #expect(words == [word(0, 1.5, "one"), word(1.5, 2, "two"), word(2, 2, "three")])
    }

    @Test("Nil words stay nil and dropped-out words collapse to nil")
    func nilWordsStayNilAndDroppedOutWordsCollapseToNil() {
        #expect(OpenCastTranscriptSegmentNormalizer.normalizedWords(nil, within: 0, 2) == nil)
        #expect(OpenCastTranscriptSegmentNormalizer.normalizedWords(
            [word(.nan, 1, "bad"), word(0, .infinity, "worse"), word(0, 1, "")],
            within: 0, 2
        ) == nil)
    }

    @Test("Zero-width words survive normalization")
    func zeroWidthWordsSurviveNormalization() {
        let words = OpenCastTranscriptSegmentNormalizer.normalizedWords(
            [word(1, 1, "blip")],
            within: 0, 2
        )

        #expect(words == [word(1, 1, "blip")])
    }

    @Test("Word normalization is idempotent")
    func wordNormalizationIsIdempotent() {
        let first = OpenCastTranscriptSegmentNormalizer.normalizedWords(
            [word(-2, 5, "a"), word(1, 1.2, "b"), word(4, 9, "c")],
            within: 0, 6
        )
        let second = OpenCastTranscriptSegmentNormalizer.normalizedWords(first, within: 0, 6)

        #expect(first != nil)
        #expect(first == second)
    }

    private func word(
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String
    ) -> OpenCastTranscriptWord {
        OpenCastTranscriptWord(start: start, end: end, text: text)
    }

    private func segment(
        id: Int,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [OpenCastTranscriptWord]? = nil
    ) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: text,
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01,
            words: words
        )
    }
}
