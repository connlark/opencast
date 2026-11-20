import Foundation

/// The app's own saves round-trip through the remote-change notification, so each consumes one
/// self-save credit instead of reloading. The 60-second foreground staleness refresh is the
/// backstop for a remote change that lands while a stale credit is outstanding.
struct SyncedStoreRemoteChangeArbiter {
    private var consumedSelfSaveCount = 0

    mutating func shouldScheduleReload(
        changedStoreURL: URL?,
        syncedStoreURL: URL?,
        selfSaveCount: Int
    ) -> Bool {
        guard let syncedStoreURL, let changedStoreURL else {
            return true
        }
        guard changedStoreURL == syncedStoreURL else {
            return false
        }
        guard selfSaveCount > consumedSelfSaveCount else {
            return true
        }

        consumedSelfSaveCount += 1
        return false
    }
}
