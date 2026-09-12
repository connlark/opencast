import Foundation
import OpenCastTranscription

nonisolated enum EpisodeAdBoundaryRefiner {
    @concurrent
    static func refined(
        _ document: EpisodeAdAnalysisDocument,
        transcript: EpisodeTranscriptDocument
    ) async -> EpisodeAdAnalysisDocument {
        refine(document, transcript: transcript)
    }

    static func refine(
        _ document: EpisodeAdAnalysisDocument,
        transcript: EpisodeTranscriptDocument
    ) -> EpisodeAdAnalysisDocument {
        guard document.policy == EpisodeAdAnalysisContract.wordBoundaryPolicy,
              document.spans.contains(where: {
                  $0.startBoundary != nil || $0.endBoundary != nil || $0.boundaryRefinement != nil
              })
        else { return document }
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcript.segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try? encoder.encode(segments)
        let digest = encoded.map { OpenCastSHA256.hash($0 + Data(transcript.sourceFileSHA256.utf8)) } ?? ""
        let indices = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
        var output = document
        output.spans = document.spans.map { original in
            var span = original
            let previous = original.boundaryRefinement
            let startTime = previous?.originalStartTime ?? span.startTime
            let endTime = previous?.originalEndTime ?? span.endTime
            let startID = previous?.originalStartSegmentID ?? span.startSegmentID
            let endID = previous?.originalEndSegmentID ?? span.endSegmentID
            // Only an original boundary (or its one-segment inward fallback)
            // may be refined. A misplaced anchor cannot translate a whole ad.
            func resolve(_ anchor: OpenCastAdBoundary?, isStart: Bool) -> OpenCastAdBoundaryResolution {
                let fallback = isStart ? startTime : endTime
                guard !digest.isEmpty else { return .init(time: fallback, fallbackReason: "timing_digest_unavailable") }
                guard let anchor else { return .init(time: fallback, fallbackReason: "missing_anchor") }
                guard let index = indices[anchor.segmentID],
                      let coarseIndex = indices[isStart ? startID : endID],
                      (isStart ? (coarseIndex - 1...coarseIndex) : (coarseIndex...coarseIndex + 1)).contains(index)
                else { return .init(time: fallback, fallbackReason: "anchor_outside_boundary") }
                return OpenCastAdBoundaryResolver.resolve(
                    anchor, in: segments[index], isStart: isStart, fallback: fallback
                )
            }
            var start = resolve(span.startBoundary, isStart: true)
            var end = resolve(span.endBoundary, isStart: false)
            if !start.time.isFinite || !end.time.isFinite || start.time < 0
                || end.time <= start.time || end.time > transcript.audioDuration + 0.5
                || end.time - start.time > 600 {
                start = .init(time: startTime, fallbackReason: "invalid_refined_interval")
                end = .init(time: endTime, fallbackReason: "invalid_refined_interval")
            }
            span.startTime = start.time
            span.endTime = end.time
            span.startSegmentID = start.isRefined ? (span.startBoundary?.segmentID ?? startID) : startID
            span.endSegmentID = end.isRefined ? (span.endBoundary?.segmentID ?? endID) : endID
            span.boundaryRefinement = .init(
                revision: OpenCastAdBoundaryResolver.revision, wordTimingDigest: digest,
                originalStartTime: startTime, originalEndTime: endTime,
                originalStartSegmentID: startID, originalEndSegmentID: endID,
                start: start, end: end
            )
            return span
        }
        // Refining an inward-trimmed edge must not bypass the server's
        // episode-wide union-duration guard (including overlapping tiers).
        var coveredEnd = -Double.infinity
        let coveredDuration = output.spans.sorted { $0.startTime < $1.startTime }.reduce(0.0) { total, span in
            let uncovered = max(0, span.endTime - max(span.startTime, coveredEnd))
            coveredEnd = max(coveredEnd, span.endTime)
            return total + uncovered
        }
        if coveredDuration > max(600, transcript.audioDuration * 0.25) {
            output.spans = output.spans.map { span in
                guard var refinement = span.boundaryRefinement else { return span }
                var fallback = span
                fallback.startTime = refinement.originalStartTime
                fallback.endTime = refinement.originalEndTime
                fallback.startSegmentID = refinement.originalStartSegmentID
                fallback.endSegmentID = refinement.originalEndSegmentID
                refinement.start = .init(time: fallback.startTime, fallbackReason: "refined_ad_budget_exceeded")
                refinement.end = .init(time: fallback.endTime, fallbackReason: "refined_ad_budget_exceeded")
                fallback.boundaryRefinement = refinement
                return fallback
            }
        }
        return output
    }
}
