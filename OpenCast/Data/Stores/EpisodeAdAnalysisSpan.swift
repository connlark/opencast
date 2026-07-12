import Foundation

nonisolated struct EpisodeAdAnalysisSpan: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var kind: EpisodeAdAnalysisSpanKind
    var label: String
    var startSegmentID: Int
    var endSegmentID: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double
    var evidenceQuote: String

    func contains(segmentID: Int) -> Bool {
        startSegmentID <= segmentID && segmentID <= endSegmentID
    }
}
