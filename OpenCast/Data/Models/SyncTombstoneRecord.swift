import Foundation
import SwiftData

@Model
final class SyncTombstoneRecord {
    /// A `SyncTombstoneScope` raw value; stored as a plain string because
    /// CloudKit-synced models need default-or-optional properties.
    var scope: String = ""
    var feedURL: String = ""
    var episodeID: String?
    var deletedAt: Date = Date()

    init(
        scope: SyncTombstoneScope,
        feedURL: String,
        episodeID: String? = nil,
        deletedAt: Date = .now
    ) {
        self.scope = scope.rawValue
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.deletedAt = deletedAt
    }
}
