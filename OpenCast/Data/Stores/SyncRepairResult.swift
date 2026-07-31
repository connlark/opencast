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

    var duplicateRecordsFound: Int {
        duplicateSubscriptionRecordsFound + duplicateProgressRecordsFound
    }

    var groupsMerged: Int {
        subscriptionGroupsMerged + progressGroupsMerged
    }

    var recordsDeleted: Int {
        subscriptionRecordsDeleted + progressRecordsDeleted
    }

    var tombstonedRecordsDeleted: Int {
        tombstonedSubscriptionRecordsDeleted + tombstonedProgressRecordsDeleted
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
