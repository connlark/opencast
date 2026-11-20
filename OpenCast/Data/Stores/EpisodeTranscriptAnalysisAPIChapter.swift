import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIChapter: Codable, Sendable, Equatable {
    var title: String
    /// An original segment ID at every episode length, so the local ID-to-time mapping applies.
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
