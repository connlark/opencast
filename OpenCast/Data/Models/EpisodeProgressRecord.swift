import Foundation
import SwiftData

@Model
final class EpisodeProgressRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var position: Double = 0
    var duration: Double?
    var isPlayed: Bool = false
    var updatedAt: Date = Date()
    /// Stable per-record identity so duplicate repair picks the same winner on
    /// every device (smallest UUID wins); peers that chose opposite winners
    /// used to cross-delete both copies. Records imported from builds that
    /// predate the field carry "".
    var dedupeUUID: String = ""

    init(
        episodeID: String,
        podcastID: String,
        position: Double = 0,
        duration: Double? = nil,
        isPlayed: Bool = false,
        updatedAt: Date = Date(),
        dedupeUUID: String = UUID().uuidString
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.position = position
        self.duration = duration
        self.isPlayed = isPlayed
        self.updatedAt = updatedAt
        self.dedupeUUID = dedupeUUID
    }
}
