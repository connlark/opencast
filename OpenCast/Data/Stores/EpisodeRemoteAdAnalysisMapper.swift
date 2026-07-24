import Foundation
import OpenCastTranscription

/// Validates a cloud detect job's `ad_analysis` block against the imported
/// transcript and builds the persisted analysis document. Strict by design:
/// a policy drift, an unknown span kind, or broken timing throws — the
/// caller falls back to on-device analysis rather than skipping audio it
/// cannot trust. The fingerprint is computed locally at import time so
/// `isCurrentAnalysisDocument` matches exactly.
nonisolated enum EpisodeRemoteAdAnalysisMapper {
    struct ValidationError: Error, Equatable {
        let reason: String
    }

    private static let endTimeToleranceSeconds = 0.5

    static func document(
        from success: OpenCastRemoteTranscriptionAdAnalysisSuccess,
        transcript: EpisodeTranscriptDocument,
        requestID: String
    ) throws -> EpisodeAdAnalysisDocument {
        guard success.policy == EpisodeAdAnalysisContract.expectedPolicy else {
            throw ValidationError(reason: "unexpected policy \(success.policy)")
        }

        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcript.segments)
        guard !segments.isEmpty else {
            throw ValidationError(reason: "transcript has no segments")
        }
        let segmentIDs = Set(segments.map(\.id))
        let maxEndTime = transcript.audioDuration + Self.endTimeToleranceSeconds

        let spans = try success.spans.enumerated().map { index, span in
            guard let kind = EpisodeAdAnalysisSpanKind(rawValue: span.kind) else {
                throw ValidationError(reason: "unknown span kind \(span.kind)")
            }
            guard span.startTime.isFinite,
                  span.endTime.isFinite,
                  span.startTime >= 0,
                  span.endTime > span.startTime,
                  span.endTime <= maxEndTime
            else {
                throw ValidationError(reason: "invalid span timing")
            }
            guard span.startSegmentID <= span.endSegmentID,
                  segmentIDs.contains(span.startSegmentID),
                  segmentIDs.contains(span.endSegmentID)
            else {
                throw ValidationError(reason: "span segment ids outside transcript")
            }
            guard span.confidence.isFinite else {
                throw ValidationError(reason: "invalid span confidence")
            }
            return EpisodeAdAnalysisSpan(
                id: index,
                kind: kind,
                label: span.label,
                startSegmentID: span.startSegmentID,
                endSegmentID: span.endSegmentID,
                startTime: span.startTime,
                endTime: span.endTime,
                confidence: min(max(span.confidence, 0), 1),
                evidenceQuote: span.evidenceQuote
            )
        }

        let fingerprint = EpisodeAdAnalysisFileStore().transcriptFingerprint(
            for: transcript,
            segments: segments
        )
        return EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            requestID: requestID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: segments.count,
            transcriptState: .completed,
            model: success.model,
            policy: success.policy,
            spans: spans,
            warnings: success.warnings,
            usage: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }
}
