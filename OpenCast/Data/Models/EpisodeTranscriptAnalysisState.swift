enum EpisodeTranscriptAnalysisState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
}
