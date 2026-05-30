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

    init(
        episodeID: String,
        podcastID: String,
        position: Double = 0,
        duration: Double? = nil,
        isPlayed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.position = position
        self.duration = duration
        self.isPlayed = isPlayed
        self.updatedAt = updatedAt
    }
}
