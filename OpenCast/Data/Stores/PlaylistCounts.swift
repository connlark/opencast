import Foundation

nonisolated struct PlaylistCounts: Equatable, Sendable {
    var itemCount: Int
    var unplayedCount: Int
    var remainingDuration: TimeInterval
}
