import Foundation

/// A displayed recap bullet: its text and the resolved start time of the
/// segment it cites, which the sheet seeks to on tap.
nonisolated struct TranscriptRecapResultBullet: Codable, Equatable, Sendable {
    var text: String
    var segmentID: Int
    var start: TimeInterval
}
