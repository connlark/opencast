import Foundation
import SwiftData

/// Synced deletion marker that makes destructive actions stick across devices.
///
/// Deleting synced records by local fetch only removes the copies this device
/// has imported; a CloudKit duplicate that hasn't imported yet re-syncs later
/// and resurrects the deleted data everywhere. Tombstones travel through the
/// same private database, and `SyncDuplicateRepairer` deletes on sight any
/// record in scope whose own timestamp predates `deletedAt`. Re-creating the
/// same logical record afterwards (resubscribe, new listening) survives
/// because its timestamp is newer than the tombstone.
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
