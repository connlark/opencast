import Foundation
import OpenCastTranscription

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
    var startBoundary: OpenCastAdBoundary? = nil
    var endBoundary: OpenCastAdBoundary? = nil
    var boundaryRefinement: EpisodeAdBoundaryRefinement? = nil

    func contains(segmentID: Int) -> Bool {
        startSegmentID <= segmentID && segmentID <= endSegmentID
    }
}
