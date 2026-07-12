#if DEBUG
import Foundation

nonisolated struct TranscriptionProofCheckpointReport: Codable, Sendable, Equatable {
    var id: Int
    var completedDuration: TimeInterval
    var segmentCount: Int
    var textPreview: String
    var createdAt: Date
}
#endif
