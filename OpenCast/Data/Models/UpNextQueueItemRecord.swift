import Foundation
import SwiftData

/// Device-local persistence for the explicit playback queue. Never synced.
@Model
final class UpNextQueueItemRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var sequence: Int = 0
    var enqueuedAt: Date = Date()

    init(
        episodeID: String,
        podcastID: String,
        sequence: Int,
        enqueuedAt: Date = .now
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.sequence = sequence
        self.enqueuedAt = enqueuedAt
    }
}
