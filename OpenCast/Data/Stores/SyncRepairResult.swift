struct SyncRepairResult: Equatable, Sendable {
    var duplicateSubscriptionRecordsFound = 0
    var subscriptionGroupsMerged = 0
    var subscriptionRecordsDeleted = 0
    var duplicateProgressRecordsFound = 0
    var progressGroupsMerged = 0
    var progressRecordsDeleted = 0
    var tombstonedSubscriptionRecordsDeleted = 0
    var tombstonedProgressRecordsDeleted = 0
    var normalizedProgressRecords = 0
    var expiredTombstonesDeleted = 0
    var duplicatePlaylistRecordsFound = 0
    var playlistGroupsMerged = 0
    var playlistRecordsDeleted = 0
    var duplicatePlaylistItemRecordsFound = 0
    var playlistItemGroupsMerged = 0
    var playlistItemRecordsDeleted = 0
    var tombstonedPlaylistRecordsDeleted = 0
    var tombstonedPlaylistItemRecordsDeleted = 0

    var duplicateRecordsFound: Int {
        duplicateSubscriptionRecordsFound
            + duplicateProgressRecordsFound
            + duplicatePlaylistRecordsFound
            + duplicatePlaylistItemRecordsFound
    }

    var groupsMerged: Int {
        subscriptionGroupsMerged + progressGroupsMerged + playlistGroupsMerged + playlistItemGroupsMerged
    }

    var recordsDeleted: Int {
        subscriptionRecordsDeleted + progressRecordsDeleted + playlistRecordsDeleted + playlistItemRecordsDeleted
    }

    var tombstonedRecordsDeleted: Int {
        tombstonedSubscriptionRecordsDeleted
            + tombstonedProgressRecordsDeleted
            + tombstonedPlaylistRecordsDeleted
            + tombstonedPlaylistItemRecordsDeleted
    }

    /// True when the pass deleted or rewrote playlist or playlist item rows,
    /// so the playlist store must reload.
    var playlistRowsChanged: Bool {
        duplicatePlaylistRecordsFound > 0
            || playlistGroupsMerged > 0
            || playlistRecordsDeleted > 0
            || duplicatePlaylistItemRecordsFound > 0
            || playlistItemGroupsMerged > 0
            || playlistItemRecordsDeleted > 0
            || tombstonedPlaylistRecordsDeleted > 0
            || tombstonedPlaylistItemRecordsDeleted > 0
    }

    var hasIssues: Bool {
        duplicateRecordsFound > 0 || tombstonedRecordsDeleted > 0 || normalizedProgressRecords > 0
    }

    /// True when the repair pass changed the store at all, including
    /// bookkeeping-only tombstone expiry that shouldn't read as "Repaired".
    var hasChanges: Bool {
        hasIssues || expiredTombstonesDeleted > 0
    }

    var displayStatus: String {
        hasIssues ? "Repaired" : "No Issues"
    }
}
