import OpenCastTranscription

nonisolated struct EpisodeTranscriptAnalysisPreparation: Sendable {
    let segments: [OpenCastTranscriptSegment]
    let fingerprint: String
    let relativePath: String
    let request: EpisodeTranscriptAnalysisAPIRequest
}
