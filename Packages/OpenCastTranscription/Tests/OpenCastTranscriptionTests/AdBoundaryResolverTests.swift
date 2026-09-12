import Foundation
import Testing
@testable import OpenCastTranscription

struct AdBoundaryResolverTests {
    private func segment() -> OpenCastTranscriptSegment {
        .init(id: 37, start: 111.16, end: 117.6,
              text: "conservationfund .org. President Trump spoke",
              avgLogProbability: 0, noSpeechProbability: 0,
              words: [
                  .init(start: 111.16, end: 111.68, text: "conservationfund"),
                  .init(start: 111.68, end: 112.2, text: ".org."),
                  .init(start: 113, end: 113.52, text: "President"),
                  .init(start: 113.52, end: 113.9, text: "Trump"),
                  .init(start: 113.9, end: 117.6, text: "spoke")
              ])
    }

    @Test func preservesReturningNews() {
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: "conservationfund .org."),
            in: segment(), isStart: false, fallback: 117.6
        )
        #expect(result.time == 112.2)
        #expect(result.wordIndex == 1)
        #expect(result.isRefined)
    }

    @Test func independentlyRefinesMixedOpening() {
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: "President Trump"),
            in: segment(), isStart: true, fallback: 111.16
        )
        #expect(result.time == 113)
        #expect(result.wordIndex == 2)
    }

    @Test func invalidWordsKeepFallback() {
        var value = segment()
        let start = value.words![1].start
        value.words?[1].end = start
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: "conservationfund .org."),
            in: value, isStart: false, fallback: 117.6
        )
        #expect(result.time == 117.6)
        #expect(result.fallbackReason == "zero_duration_word")
    }

    @Test func incompleteWordsKeepFallback() {
        var value = segment()
        value.words?.removeLast()
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: ".org."), in: value, isStart: false, fallback: 117.6
        )
        #expect(result.fallbackReason == "word_text_mismatch")
    }

    @Test func repeatedPhraseIsNotReanchored() {
        var value = segment()
        value.words?[2].text = "org"
        value.text = "conservationfund .org. org Trump spoke"
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: "org"), in: value, isStart: false, fallback: 117.6
        )
        #expect(result.fallbackReason == "ambiguous_or_missing_quote")
    }

    @Test func doesNotInterpolateInsideAWord() {
        var value = segment()
        value.words?[4].text = "don't"
        value.text = "conservationfund .org. President Trump don't"
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: "don"), in: value, isStart: false, fallback: 117.6
        )
        #expect(result.fallbackReason == "partial_word_anchor")
    }

    @Test func unicodeTokenRules() {
        #expect(OpenCastAdBoundaryResolver.normalizedTokens("CAFÉ—İ Ⅳ ² don't .org.") ==
                ["café", "i̇", "ⅳ", "²", "don", "t", "org"])
        #expect(OpenCastAdBoundaryResolver.normalizedTokens("Straße STRASSE σ ς ΟΣ İSTANBUL") ==
                ["straße", "strasse", "σ", "ς", "οσ", "i̇stanbul"])
    }

    @Test func adjustedProvenanceSurvivesRemoteAndLocalCoding() throws {
        let remote = try JSONDecoder().decode(OpenCastRemoteTranscriptSegment.self, from: Data(
            #"{"id":37,"start":111.16,"end":117.6,"text":"ad","word_timings_adjusted":true}"#.utf8
        ))
        #expect(remote.wordTimingsAdjusted == true)
        var value = segment()
        value.wordTimingsAdjusted = remote.wordTimingsAdjusted
        let decoded = try JSONDecoder().decode(OpenCastTranscriptSegment.self, from: JSONEncoder().encode(value))
        let result = OpenCastAdBoundaryResolver.resolve(
            .init(segmentID: 37, quote: ".org."), in: decoded, isStart: false, fallback: 117.6
        )
        #expect(result.time == 117.6)
        #expect(result.fallbackReason == "adjusted_word_timing")
    }

    @Test func publishedSegmentStartAdjustmentKeepsCoarseFallback() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/RemoteSegmentStartAdjustment.json")
        let remote = try JSONDecoder().decode(OpenCastRemoteTranscriptSegment.self, from: Data(contentsOf: url))
        let local = OpenCastTranscriptSegment(id: remote.id, start: remote.start, end: remote.end, text: remote.text,
            avgLogProbability: 0, noSpeechProbability: 0,
            words: remote.words?.map { .init(start: $0.start, end: $0.end, text: $0.text) }, wordTimingsAdjusted: remote.wordTimingsAdjusted)
        let restored = try JSONDecoder().decode(OpenCastTranscriptSegment.self, from: JSONEncoder().encode(local))
        let result = OpenCastAdBoundaryResolver.resolve(.init(segmentID: 0, quote: "Sponsor"), in: restored, isStart: true, fallback: 2)
        #expect(restored.words?.first?.start == 1)
        #expect(result.time == 2)
        #expect(result.fallbackReason == "adjusted_word_timing")
    }

    @Test func malformedOptionalAnchorBecomesUnresolvable() throws {
        for json in ["{}", "12", "{\"segment_id\":\"bad\",\"quote\":[]}"] {
            let value = try JSONDecoder().decode(OpenCastAdBoundary.self, from: Data(json.utf8))
            #expect(value.quote.isEmpty)
        }
    }
}
