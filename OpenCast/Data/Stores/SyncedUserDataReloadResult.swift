import Foundation

struct SyncedUserDataReloadResult: Equatable, Sendable {
    let activePodcastIDsChanged: Bool
    let activeSubscriptionRecordsChanged: Bool
    let progressRecordsChanged: Bool

    // Progress-only imports count: a genuinely-remote progress change can
    // introduce duplicates that should repair mid-session rather than on the
    // next foreground activation. Requires the self-save filter
    // (SyncedStoreRemoteChangeArbiter) so the app's own 5-second progress
    // flushes never reach this path.
    var shouldProcessImportedSubscriptions: Bool {
        activePodcastIDsChanged || activeSubscriptionRecordsChanged || progressRecordsChanged
    }
}
