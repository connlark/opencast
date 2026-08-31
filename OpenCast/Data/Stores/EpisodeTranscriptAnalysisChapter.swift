import Foundation

nonisolated struct EpisodeTranscriptAnalysisChapter: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var title: String
    var startSegmentID: Int
    var endSegmentID: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Double

    func contains(segmentID: Int) -> Bool {
        startSegmentID <= segmentID && segmentID <= endSegmentID
    }
}
