import Foundation
import SwiftData

@Model
final class EpisodeProgressRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var position: Double = 0
    var duration: Double?
    var isPlayed: Bool = false
    var archivedAt: Date?
    var updatedAt: Date = Date()
    /// Never reassigned: duplicate repair keeps the smallest non-empty UUID on every device.
    var dedupeUUID: String = ""

    init(
        episodeID: String,
        podcastID: String,
        position: Double = 0,
        duration: Double? = nil,
        isPlayed: Bool = false,
        archivedAt: Date? = nil,
        updatedAt: Date = Date(),
        dedupeUUID: String = UUID().uuidString
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.position = position
        self.duration = duration
        self.isPlayed = isPlayed
        self.archivedAt = archivedAt
        self.updatedAt = updatedAt
        self.dedupeUUID = dedupeUUID
    }
}
