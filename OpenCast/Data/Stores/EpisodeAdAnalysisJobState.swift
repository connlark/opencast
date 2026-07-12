enum EpisodeAdAnalysisJobState {
    case unavailable(String)
    case ready
    case running
    case completed(EpisodeAdAnalysisRecord, isStale: Bool)
    case failed(EpisodeAdAnalysisRecord, isStale: Bool)
}
