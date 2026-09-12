import Foundation
import OpenCastTranscription

nonisolated struct EpisodeAdBoundaryRefinement: Codable, Sendable, Equatable {
    var revision: String
    var wordTimingDigest: String
    var originalStartTime: TimeInterval
    var originalEndTime: TimeInterval
    var originalStartSegmentID: Int
    var originalEndSegmentID: Int
    var start: OpenCastAdBoundaryResolution
    var end: OpenCastAdBoundaryResolution
}
