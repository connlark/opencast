import Foundation

struct SyncedUserDataReloadResult: Equatable, Sendable {
    let activePodcastIDsChanged: Bool
    let activeSubscriptionRecordsChanged: Bool
    let progressRecordsChanged: Bool

    var shouldProcessImportedSubscriptions: Bool {
        activePodcastIDsChanged || activeSubscriptionRecordsChanged
    }
}
