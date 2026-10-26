import OpenCastAnalysis
import OpenCastTranscription

nonisolated struct EpisodeAdAnalysisPreparation: Sendable {
    let segments: [OpenCastTranscriptSegment]
    let fingerprint: String
    let relativePath: String
    /// The request as the device pipeline reads it.
    let request: AdAnalysisRequest
    /// Identifies every input the run depends on; a resume needs the same.
    let inputDigest: String
}
