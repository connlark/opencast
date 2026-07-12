import Foundation
import SwiftData

/// Device-local persistence for pending ad-free pass queue items. Never
/// synced; registered only in the local SwiftData configuration.
@Model
final class AdFreePassQueueItemRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var originRawValue: String = ""
    var enqueuedAt: Date = Date()
    var sequence: Int = 0

    init(
        episodeID: String,
        podcastID: String,
        originRawValue: String,
        enqueuedAt: Date = .now,
        sequence: Int
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.originRawValue = originRawValue
        self.enqueuedAt = enqueuedAt
        self.sequence = sequence
    }
}
