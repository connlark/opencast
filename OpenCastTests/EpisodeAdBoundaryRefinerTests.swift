import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
struct EpisodeAdBoundaryRefinerTests {
    private func transcript() -> EpisodeTranscriptDocument {
        let segment = OpenCastTranscriptSegment(
            id: 0, start: 0, end: 8,
            text: "The show. Sponsor offer ends. President speaks.",
            avgLogProbability: 0, noSpeechProbability: 0,
            words: [
                .init(start: 0, end: 0.5, text: "The"), .init(start: 0.5, end: 1, text: "show."),
                .init(start: 1.2, end: 2, text: "Sponsor"), .init(start: 2, end: 3, text: "offer"),
                .init(start: 3, end: 4, text: "ends."), .init(start: 5, end: 6, text: "President"),
                .init(start: 6, end: 8, text: "speaks.")
            ]
        )
        return .init(
            schemaVersion: 3, episodeID: "episode", podcastID: "show", sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 100, sourceFileSHA256: "audio-hash", modelIdentifier: "test", modelVersion: "1",
            modelTreeSHA256: "", languageCode: "en", audioDuration: 80, checkpoints: [], segments: [segment],
            text: segment.text, timings: EpisodeTranscriptTimings(), createdAt: .now, updatedAt: .now
        )
    }

    private func document() -> EpisodeAdAnalysisDocument {
        .init(
            schemaVersion: 1, episodeID: "episode", podcastID: "show", requestID: "request",
            transcriptFingerprint: "fingerprint", transcriptUpdatedAt: .now, transcriptSegmentCount: 1,
            model: "gemini-3.8-flash", policy: "promo_ad_breaks_v3",
            spans: [.init(id: 0, kind: .insertedAd, label: "Sponsor", startSegmentID: 0, endSegmentID: 0,
                          startTime: 0, endTime: 8, confidence: 1, evidenceQuote: "Sponsor offer",
                          startBoundary: .init(segmentID: 0, quote: "Sponsor offer"),
                          endBoundary: .init(segmentID: 0, quote: "offer ends"))],
            warnings: [], usage: nil, createdAt: .now, updatedAt: .now
        )
    }

    @Test func bothEdgesRefineAndOriginalCutSurvivesPersistence() throws {
        let result = EpisodeAdBoundaryRefiner.refine(document(), transcript: transcript())
        #expect(result.spans[0].startTime == 1.2)
        #expect(result.spans[0].endTime == 4)
        #expect(result.spans[0].boundaryRefinement?.originalEndTime == 8)
        let decoded = try JSONDecoder().decode(EpisodeAdAnalysisDocument.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(EpisodeAdBoundaryRefiner.refine(decoded, transcript: transcript()).spans == result.spans)
    }

    @Test func oneUnusableEdgeKeepsOnlyThatFallback() {
        var input = document()
        input.spans[0].startBoundary?.quote = "not in this transcript"
        let result = EpisodeAdBoundaryRefiner.refine(input, transcript: transcript()).spans[0]
        #expect(result.startTime == 0)
        #expect(result.endTime == 4)
        #expect(result.boundaryRefinement?.start.isRefined == false)
    }

    @Test func changedWordTimingRecomputesInsteadOfReusingResolvedCut() {
        let old = EpisodeAdBoundaryRefiner.refine(document(), transcript: transcript())
        var changed = transcript()
        changed.segments[0].words?[4].end = 4.5
        let result = EpisodeAdBoundaryRefiner.refine(old, transcript: changed)
        #expect(result.spans[0].endTime == 4.5)
        #expect(result.spans[0].boundaryRefinement?.wordTimingDigest != old.spans[0].boundaryRefinement?.wordTimingDigest)
        changed.segments[0].words = nil
        let fallback = EpisodeAdBoundaryRefiner.refine(result, transcript: changed)
        #expect(fallback.spans[0].startTime == 0)
        #expect(fallback.spans[0].endTime == 8)
    }

    @Test func reversedResolvedIntervalRestoresBothOriginalEdges() {
        var input = document()
        input.spans[0].startBoundary?.quote = "President"
        input.spans[0].endBoundary?.quote = "show"
        let result = EpisodeAdBoundaryRefiner.refine(input, transcript: transcript()).spans[0]
        #expect(result.startTime == 0 && result.endTime == 8)
        #expect(result.boundaryRefinement?.end.fallbackReason == "invalid_refined_interval")
    }

    @Test func oldResponsesRemainUnmodified() {
        var input = document()
        input.spans[0].startBoundary = nil
        input.spans[0].endBoundary = nil
        #expect(EpisodeAdBoundaryRefiner.refine(input, transcript: transcript()) == input)
    }

    @Test func normalizationCannotCertifyOverlappingWordTimes() throws {
        var source = transcript()
        source.segments[0].words?[2].start = 0.7
        source.segments = OpenCastTranscriptSegmentNormalizer.normalized(source.segments)
        #expect(source.segments[0].words?[2].start == 1)
        #expect(source.segments[0].wordTimingsAdjusted == true)
        let decoded = try JSONDecoder().decode(EpisodeTranscriptDocument.self, from: JSONEncoder().encode(source))
        let result = EpisodeAdBoundaryRefiner.refine(document(), transcript: decoded).spans[0]
        #expect(result.startTime == 0 && result.endTime == 8)
        #expect(result.boundaryRefinement?.start.fallbackReason == "adjusted_word_timing")
    }

    @Test func outOfBoundsWordTimesKeepCoarseCut() {
        var source = transcript()
        source.segments[0].words?[6].end = 10
        let result = EpisodeAdBoundaryRefiner.refine(document(), transcript: source).spans[0]
        #expect(result.endTime == 8)
        #expect(result.boundaryRefinement?.end.fallbackReason == "adjusted_word_timing")
    }

    @Test func upstreamAdjustmentIsStickyAndChangesDigest() {
        let source = transcript()
        let before = EpisodeAdBoundaryRefiner.refine(document(), transcript: source)
        var changed = source
        changed.segments[0].wordTimingsAdjusted = true
        let after = EpisodeAdBoundaryRefiner.refine(before, transcript: changed).spans[0]
        #expect(after.startTime == 0 && after.endTime == 8)
        #expect(after.boundaryRefinement?.start.fallbackReason == "adjusted_word_timing")
        #expect(after.boundaryRefinement?.wordTimingDigest != before.spans[0].boundaryRefinement?.wordTimingDigest)
    }

    @Test func refinedZonesDoNotFillRetainedSubsecondSpeech() throws {
        var input = EpisodeAdBoundaryRefiner.refine(document(), transcript: transcript())
        var neighbor = input.spans[0]
        neighbor.id = 1
        neighbor.startTime = 4.5
        neighbor.endTime = 7
        input.spans.append(neighbor)
        let zones = EpisodeAdAnalysisZoneMapper.zones(for: input, duration: 80)
        try #require(zones.count == 2, "\(zones); \(input.spans)")
        #expect(zones[0].endTime == 4)
        #expect(zones[1].startTime == 4.5)
    }

    @Test func mixedParagraphMarksOnlySkippedWords() throws {
        let source = transcript()
        let result = EpisodeAdBoundaryRefiner.refine(document(), transcript: source)
        let mark = try #require(TranscriptAdHighlight(span: result.spans[0], segment: source.segments[0]))
        #expect(!mark.isWholeSegment)
        #expect(mark.ranges.map { String(source.segments[0].text[$0]) } == ["Sponsor", "offer", "ends"])
    }

    @Test func releaseRoutingMatchesCloudEnvironment() {
        #expect(AdAnalysisBackendConfiguration.release(for: .production)?.workerBaseURL == AdAnalysisBackendConfiguration.production.workerBaseURL)
        #expect(AdAnalysisBackendConfiguration.release(for: .sandbox)?.workerBaseURL == AdAnalysisBackendConfiguration.prodStaging.workerBaseURL)
        #expect(AdAnalysisBackendConfiguration.release(for: .xcode)?.workerBaseURL == AdAnalysisBackendConfiguration.prodStaging.workerBaseURL)
        #expect(AdAnalysisBackendConfiguration.release(for: .unknown("test")) == nil)
    }
}
