import Foundation

struct SyncedUserDataReloadResult: Equatable, Sendable {
    let activePodcastIDsChanged: Bool
    let activeSubscriptionRecordsChanged: Bool
    let progressRecordsChanged: Bool

    // Progress-only imports count, so remote duplicates repair mid-session; this relies on the
    // self-save filter keeping the app's own progress flushes off this path.
    var shouldProcessImportedSubscriptions: Bool {
        activePodcastIDsChanged || activeSubscriptionRecordsChanged || progressRecordsChanged
    }
}
