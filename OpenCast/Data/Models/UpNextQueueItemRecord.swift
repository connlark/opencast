import Foundation
import SwiftData

/// Device-local: never synced.
@Model
final class UpNextQueueItemRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var sequence: Int = 0
    var enqueuedAt: Date = Date()
    /// The playlist that poured this row in; nil for a hand-queued episode.
    var sourcePlaylistID: String?

    init(
        episodeID: String,
        podcastID: String,
        sequence: Int,
        enqueuedAt: Date = .now,
        sourcePlaylistID: String? = nil
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.sequence = sequence
        self.enqueuedAt = enqueuedAt
        self.sourcePlaylistID = sourcePlaylistID
    }
}
