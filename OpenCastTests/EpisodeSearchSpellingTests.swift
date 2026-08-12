import Testing
@testable import OpenCast

@Suite("Episode search spelling")
struct EpisodeSearchSpellingTests {
    @Test("One-edit distance includes insertion deletion substitution and transposition")
    func boundedDamerauDistance() {
        #expect(EpisodeSearchSpelling.isWithinOneEdit("kubernets", "kubernetes"))
        #expect(EpisodeSearchSpelling.isWithinOneEdit("aspergilus", "aspergillus"))
        #expect(EpisodeSearchSpelling.isWithinOneEdit("corol", "coral"))
        #expect(EpisodeSearchSpelling.isWithinOneEdit("keybaord", "keyboard"))
        #expect(!EpisodeSearchSpelling.isWithinOneEdit("keyboard", "keyboardsx"))
        #expect(!EpisodeSearchSpelling.isWithinOneEdit("coral", "cider"))
    }

    @Test("Corpus provenance wins before raw frequency")
    func corpusProvenanceRanking() throws {
        let titleCandidate = EpisodeSearchCorrectionCandidate(
            term: "mesophotic",
            titleDocumentCount: 1,
            podcastTitleDocumentCount: 0,
            bodyDocumentCount: 0,
            transcriptDocumentCount: 0,
            documentCount: 1,
            occurrenceCount: 1
        )
        let frequentBodyCandidate = EpisodeSearchCorrectionCandidate(
            term: "mesophtics",
            titleDocumentCount: 0,
            podcastTitleDocumentCount: 0,
            bodyDocumentCount: 20,
            transcriptDocumentCount: 0,
            documentCount: 20,
            occurrenceCount: 80
        )

        let best = try #require(
            EpisodeSearchSpelling.bestCandidate(
                for: "mesophtic",
                from: [frequentBodyCandidate, titleCandidate]
            )
        )
        #expect(best.term == "mesophotic")
    }

    @Test("Equal-confidence corrections remain ambiguous")
    func ambiguousCorrectionIsRejected() {
        let first = candidate(term: "trade")
        let second = candidate(term: "trace")
        #expect(
            EpisodeSearchSpelling.bestCandidate(
                for: "trare",
                from: [first, second]
            ) == nil
        )
    }

    @Test("A unique long corpus root supplies a conservative morphological fallback")
    func morphologicalFallback() throws {
        let magnetic = candidate(term: "magnetic")
        let correction = try #require(
            EpisodeSearchSpelling.bestMorphologicalCandidate(
                for: "magnetoreception",
                from: [magnetic]
            )
        )
        #expect(correction.term == "magnetic")
    }

    @Test("Corpus plurals can supply a one-edit singular correction")
    func inflectionalCorrection() throws {
        let plural = candidate(term: "chromatophores")
        let correction = try #require(
            EpisodeSearchSpelling.bestCandidate(
                for: "chromatophroe",
                from: [plural]
            )
        )
        #expect(correction.term == "chromatophore")
    }

    private func candidate(term: String) -> EpisodeSearchCorrectionCandidate {
        EpisodeSearchCorrectionCandidate(
            term: term,
            titleDocumentCount: 1,
            podcastTitleDocumentCount: 0,
            bodyDocumentCount: 0,
            transcriptDocumentCount: 0,
            documentCount: 1,
            occurrenceCount: 1
        )
    }
}
