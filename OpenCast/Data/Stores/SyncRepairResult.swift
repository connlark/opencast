struct SyncRepairResult: Equatable, Sendable {
    var duplicateSubscriptionRecordsFound = 0
    var subscriptionGroupsMerged = 0
    var subscriptionRecordsDeleted = 0
    var duplicateProgressRecordsFound = 0
    var progressGroupsMerged = 0
    var progressRecordsDeleted = 0

    var duplicateRecordsFound: Int {
        duplicateSubscriptionRecordsFound + duplicateProgressRecordsFound
    }

    var groupsMerged: Int {
        subscriptionGroupsMerged + progressGroupsMerged
    }

    var recordsDeleted: Int {
        subscriptionRecordsDeleted + progressRecordsDeleted
    }

    var hasIssues: Bool {
        duplicateRecordsFound > 0
    }

    var displayStatus: String {
        hasIssues ? "Repaired" : "No Issues"
    }
}
