import OpenCastTranscription

nonisolated struct EpisodeAdAnalysisPreparation: Sendable {
    let segments: [OpenCastTranscriptSegment]
    let fingerprint: String
    let relativePath: String
    let request: EpisodeAdAnalysisAPIRequest
}
