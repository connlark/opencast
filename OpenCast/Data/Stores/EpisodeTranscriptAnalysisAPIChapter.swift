import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIChapter: Codable, Sendable, Equatable {
    var title: String
    /// Chapters carry original segment ids at every episode length — the
    /// worker's internal coalescing remaps back before responding — so the
    /// local id→time mapping always applies.
    var startSegmentID: Int
    var endSegmentID: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double

    enum CodingKeys: String, CodingKey {
        case title
        case startSegmentID = "start_segment_id"
        case endSegmentID = "end_segment_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case confidence
    }
}
