/// Both analysis records persist this as its raw string.
enum EpisodeAnalysisRecordState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
}
