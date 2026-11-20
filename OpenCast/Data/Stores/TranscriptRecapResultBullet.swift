import Foundation

nonisolated struct TranscriptRecapResultBullet: Codable, Equatable, Sendable {
    var text: String
    var segmentID: Int
    var start: TimeInterval
}
