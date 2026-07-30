import Foundation

/// Decides whether a persistent-store remote-change notification warrants
/// refetching synced user data. The app's own progress saves round-trip
/// through the same notification, so each one deposits a credit
/// (`LibraryStore.syncedStoreSelfSaveCount`) and the arbiter consumes one
/// credit per synced-store notification instead of scheduling a reload.
/// A genuinely remote change that lands while a stale credit is outstanding
/// is covered by the 60-second foreground staleness refresh in
/// `OpenCastRootLifecycleModifier` — that timer is the deliberate backstop
/// for this filter and must stay.
struct SyncedStoreRemoteChangeArbiter {
    private var consumedSelfSaveCount = 0

    mutating func shouldScheduleReload(
        changedStoreURL: URL?,
        syncedStoreURL: URL?,
        selfSaveCount: Int
    ) -> Bool {
        // Without both URLs the change cannot be attributed; reload and leave
        // any credits unconsumed.
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
