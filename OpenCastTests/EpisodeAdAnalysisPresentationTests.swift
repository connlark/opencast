import Foundation
import OpenCastTranscription
import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad confidence and partial transcript presentation")
struct EpisodeAdAnalysisPresentationTests {
    private func span(_ id: Int = 0, _ start: Double, _ end: Double, confidence: Double = 0.95) -> EpisodeAdAnalysisSpan {
        .init(id: id, kind: .hostReadAd, label: confidence >= 0.8 ? "Sponsor" : "Possible sponsor",
              startSegmentID: 0, endSegmentID: 0, startTime: start, endTime: end, confidence: confidence, evidenceQuote: "Sponsor words")
    }

    private func segment(words: [OpenCastTranscriptWord]? = nil, text: String = "Sponsor words. News returns.") -> OpenCastTranscriptSegment {
        .init(id: 0, start: 0, end: 10, text: text, avgLogProbability: -0.1, noSpeechProbability: 0, words: words)
    }

    @Test(arguments: [Optional<[OpenCastTranscriptWord]>.none, []])
    func partialWithoutWordsPreservesMarker(words: [OpenCastTranscriptWord]?) throws {
        let mark = try #require(TranscriptAdHighlight(span: span(0, 1, 5), segment: segment(words: words)))
        #expect(mark.coverage == .unresolvedPartial)
        #expect(!mark.isWholeSegment)
        #expect(mark.label == "Sponsor")
        #expect(mark.ranges.isEmpty)
    }

    @Test func fullCoverageNeedsNoWordMappingAndNoOverlapHasNoMarker() throws {
        #expect(try #require(TranscriptAdHighlight(span: span(0, 0, 10), segment: segment())).coverage == .full)
        #expect(TranscriptAdHighlight(span: span(0, 10, 12), segment: segment()) == nil)
    }

    @Test func normalizedCasePunctuationAndURLMapToOnlyPromotionalWords() throws {
        let words: [OpenCastTranscriptWord] = [
            .init(start: 0, end: 2, text: "SPONSOR.org!"),
            .init(start: 3, end: 4, text: "News"), .init(start: 4, end: 5, text: "returns.")
        ]
        let source = segment(words: words, text: "Sponsor.ORG. News returns.")
        let mark = try #require(TranscriptAdHighlight(span: span(0, 0, 2), segment: source))
        #expect(mark.coverage == .resolvedPartial)
        #expect(mark.ranges.map { String(source.text[$0]) } == ["Sponsor.ORG"])
    }

    @Test func mappingFailureAndSilentOverlapRemainExplicitlyUnresolved() throws {
        let words: [OpenCastTranscriptWord] = [.init(start: 1, end: 3, text: "Different text")]
        #expect(try #require(TranscriptAdHighlight(span: span(0, 1, 4), segment: segment(words: words))).coverage == .unresolvedPartial)
        let silent = segment(words: [.init(start: 5, end: 9, text: "Sponsor words. News returns.")])
        #expect(try #require(TranscriptAdHighlight(span: span(0, 1, 4), segment: silent)).coverage == .unresolvedPartial)
    }

    @Test func oppositeTierOrdersPreserveAutomaticPrecedenceAndAllHighIntervals() throws {
        let high = [span(1, 0, 2), span(2, 4, 6)]
        let low = span(3, 0, 10, confidence: 0.6)
        let words: [OpenCastTranscriptWord] = [
            .init(start: 0, end: 2, text: "Sponsor"), .init(start: 2, end: 4, text: "words."),
            .init(start: 4, end: 6, text: "News"), .init(start: 6, end: 8, text: "returns.")
        ]
        for spans in [[low] + high, high + [low]] {
            let source = segment(words: words)
            let mark = try #require(TranscriptAdHighlight(spans: spans, segment: source))
            #expect(mark.isAutomaticSkip)
            #expect(mark.label == "Sponsor")
            #expect(mark.ranges.map { String(source.text[$0]) } == ["Sponsor", "News"])
            #expect(mark.hasUncertainCoverage)
        }
    }

    @Test func differentiateWithoutColorSurvivesSearchAndKaraokeStyles() throws {
        let text = "Sponsor News"
        let ad = try #require(text.range(of: "Sponsor"))
        let result = TranscriptLineTextBuilder.attributedText(text: text, spokenUpperBound: ad.upperBound,
            highlightRanges: [ad], adRanges: [ad], differentiateWithoutColor: true)
        let range = try #require(Range(ad, in: result))
        #expect(result[range].underlineStyle != nil)
        #expect(result[range].backgroundColor == .yellow.opacity(0.4))
    }

    @Test func silentAutomaticOverlapRetainsPossibleAdvertisingWords() throws {
        let source = segment(words: [
            .init(start: 2, end: 4, text: "Sponsor"), .init(start: 4, end: 6, text: "words."),
            .init(start: 6, end: 8, text: "News"), .init(start: 8, end: 10, text: "returns.")
        ])
        let mark = try #require(TranscriptAdHighlight(
            spans: [span(0, 0, 1), span(1, 2, 4, confidence: 0.6)], segment: source
        ))
        #expect(mark.coverage == .unresolvedPartial)
        #expect(mark.ranges.isEmpty)
        #expect(mark.uncertainRanges.map { String(source.text[$0]) } == ["Sponsor"])
        let styled = TranscriptLineTextBuilder.attributedText(
            text: source.text, spokenUpperBound: nil, highlightRanges: nil,
            adRanges: mark.ranges, uncertainAdRanges: mark.uncertainRanges, differentiateWithoutColor: true
        )
        let range = try #require(Range(mark.uncertainRanges[0], in: styled))
        #expect(styled[range].underlineStyle == Text.LineStyle(pattern: .dash))
    }
}
