/// Lifecycle of one transcript-derived analysis row (ad spans or chapters
/// and summary); both analysis records persist it as a raw string.
enum EpisodeAnalysisRecordState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
}
