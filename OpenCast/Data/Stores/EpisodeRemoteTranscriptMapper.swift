import Foundation
import OpenCastTranscription

/// Validates a remote transcription result against the exact local file and
/// builds the schema-3 transcript document. The wire result is never
/// persisted directly; words stay nested per segment exactly as today.
nonisolated enum EpisodeRemoteTranscriptMapper {
    static let provider = "cloudflare-workers-ai"

    enum ValidationError: Error, Equatable {
        case sourceIdentityMismatch
        case invalidDuration
        case emptyTranscript
        case invalidTimings
        case textMismatch
        case normalizedHashMismatch
        case unsupportedSchema
    }

    struct Context {
        var episodeID: String
        var podcastID: String
        var sourceAudioURL: String
        var localIdentity: OpenCastRemoteTranscriptionSourceIdentity
        var jobProvenanceToken: String?
    }

    static func document(
        from result: OpenCastRemoteTranscriptionResult,
        context: Context
    ) throws -> EpisodeTranscriptDocument {
        guard result.schemaVersion <= OpenCastRemoteTranscriptionSchema.version else {
            throw ValidationError.unsupportedSchema
        }
        guard result.sourceIdentity.sha256.lowercased() == context.localIdentity.sha256.lowercased(),
              result.sourceIdentity.byteCount == context.localIdentity.byteCount
        else {
            throw ValidationError.sourceIdentityMismatch
        }
        guard result.durationSeconds.isFinite, result.durationSeconds > 0 else {
            throw ValidationError.invalidDuration
        }
        guard result.segments.isEmpty == false else {
            throw ValidationError.emptyTranscript
        }

        let upperBound = result.durationSeconds + 0.5
        var previousSegmentStart = -Double.infinity
        var previousWordStart = -Double.infinity
        var words: [String] = []
        for segment in result.segments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end >= segment.start,
                  segment.end <= upperBound,
                  segment.start + 0.001 >= previousSegmentStart
            else {
                throw ValidationError.invalidTimings
            }
            previousSegmentStart = segment.start
            var segmentWords: [String] = []
            for word in segment.words ?? [] {
                guard word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw ValidationError.emptyTranscript
                }
                guard word.start.isFinite, word.end.isFinite,
                      word.start >= 0, word.end >= word.start, word.end <= upperBound,
                      word.start + 0.001 >= previousWordStart
                else {
                    throw ValidationError.invalidTimings
                }
                previousWordStart = word.start
                words.append(word.text)
                segmentWords.append(word.text)
            }
            guard segment.text == segmentWords.joined(separator: " ")
            else {
                throw ValidationError.textMismatch
            }
        }
        guard words.isEmpty == false else {
            throw ValidationError.emptyTranscript
        }
        let rebuiltText = words.joined(separator: " ")
        guard result.text == rebuiltText else {
            throw ValidationError.textMismatch
        }
        let normalized = OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(
            rebuiltText
        )
        guard normalized == result.provenance.normalizedTranscriptSHA256 else {
            throw ValidationError.normalizedHashMismatch
        }

        let mappedSegments = result.segments.map { segment in
            OpenCastTranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                avgLogProbability: 0,
                noSpeechProbability: 0,
                words: segment.words?.map { word in
                    OpenCastTranscriptWord(start: word.start, end: word.end, text: word.text)
                }
            )
        }
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(mappedSegments)

        // Whole-second dates: the document is compared against its
        // `.iso8601`-coded disk round trip (which drops fractional seconds)
        // by the ad-analysis freshness checks, so the in-memory copy must
        // already carry the truncated value.
        let mintedAt = Date.now.truncatedToWholeSeconds
        var document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: context.episodeID,
            podcastID: context.podcastID,
            sourceAudioURL: context.sourceAudioURL,
            sourceFileByteCount: context.localIdentity.byteCount,
            sourceFileSHA256: context.localIdentity.sha256,
            // Honest compatibility values for pre-schema-3 logic; the
            // explicit provenance fields below are the source of truth and a
            // hosted model never claims a local tree hash.
            modelIdentifier: result.provenance.modelIdentifier,
            modelVersion: result.provenance.servingContractVersion,
            modelTreeSHA256: "",
            languageCode: result.languageCode,
            audioDuration: result.durationSeconds,
            checkpoints: [],
            segments: segments,
            text: result.text,
            timings: EpisodeTranscriptTimings(),
            createdAt: mintedAt,
            updatedAt: mintedAt
        )
        document.transcriptionEngine = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        document.providerModelIdentifier = result.provenance.modelIdentifier
        document.providerModelRevision = result.provenance.modelRevision
        document.remoteServingContractVersion = result.provenance.servingContractVersion
        document.remotePipelineVersion = result.provenance.pipelineVersion
        document.remoteRequestSettingsSHA256 = result.provenance.requestSettingsSHA256
        document.remoteChunkManifestSHA256 = result.provenance.chunkManifestSHA256
        document.normalizedTranscriptSHA256 = result.provenance.normalizedTranscriptSHA256
        document.remoteJobProvenanceToken = context.jobProvenanceToken
        // Pre-pass-2 servers omit the mode and only ever hash-matched.
        document.remoteSourceMatchMode = result.provenance.sourceMatchMode
            ?? EpisodeRemoteTranscriptSourceMatchMode.serverDeviceHashMatch.rawValue
        return document
    }
}
