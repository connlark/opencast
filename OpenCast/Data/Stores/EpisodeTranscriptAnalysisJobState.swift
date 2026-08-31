enum EpisodeTranscriptAnalysisJobState {
    case unavailable(String)
    case ready
    case running
    case completed(EpisodeTranscriptAnalysisRecord, isStale: Bool)
    case failed(EpisodeTranscriptAnalysisRecord, isStale: Bool)
}
