import Foundation

nonisolated struct EpisodeAdAnalysisAPIAdSpan: Codable, Sendable, Equatable {
    var kind: EpisodeAdAnalysisSpanKind
    var label: String
    var startSegmentID: Int
    var endSegmentID: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double
    var evidenceQuote: String

    enum CodingKeys: String, CodingKey {
        case kind
        case label
        case startSegmentID = "start_segment_id"
        case endSegmentID = "end_segment_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case confidence
        case evidenceQuote = "evidence_quote"
    }
}
