import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Synced store remote change arbiter")
struct SyncedStoreRemoteChangeArbiterTests {
    private let syncedStoreURL = URL(filePath: "/stores/synced.sqlite")
    private let localStoreURL = URL(filePath: "/stores/local.sqlite")

    @Test("A remote-shaped synced-store change schedules a reload")
    func remoteChangeSchedulesReload() {
        var arbiter = SyncedStoreRemoteChangeArbiter()

        let didSchedule = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 0
        )

        #expect(didSchedule)
    }

    @Test("A self-save credit suppresses exactly one synced-store notification")
    func selfSaveCreditSuppressesOneNotification() {
        var arbiter = SyncedStoreRemoteChangeArbiter()

        let didScheduleForSelfSave = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 1
        )
        let didScheduleForRemoteChange = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 1
        )

        #expect(!didScheduleForSelfSave)
        #expect(didScheduleForRemoteChange)
    }

    @Test("Credits accumulate one skip per self-save")
    func creditsAccumulatePerSelfSave() {
        var arbiter = SyncedStoreRemoteChangeArbiter()

        let didScheduleFirst = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 2
        )
        let didScheduleSecond = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 2
        )
        let didScheduleThird = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 2
        )

        #expect(!didScheduleFirst)
        #expect(!didScheduleSecond)
        #expect(didScheduleThird)
    }

    @Test("A local-store change neither reloads nor consumes a credit")
    func localStoreChangeIsIgnoredWithoutConsumingCredit() {
        var arbiter = SyncedStoreRemoteChangeArbiter()

        let didScheduleForLocalChange = arbiter.shouldScheduleReload(
            changedStoreURL: localStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 1
        )
        let didScheduleForSelfSave = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 1
        )

        #expect(!didScheduleForLocalChange)
        #expect(!didScheduleForSelfSave)
    }

    @Test("An unattributable notification reloads without consuming a credit")
    func unattributableNotificationReloadsConservatively() {
        var arbiter = SyncedStoreRemoteChangeArbiter()

        let didScheduleWithoutChangedURL = arbiter.shouldScheduleReload(
            changedStoreURL: nil,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 1
        )
        let didScheduleWithoutSyncedURL = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: nil,
            selfSaveCount: 1
        )
        let didScheduleForSelfSave = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: 1
        )

        #expect(didScheduleWithoutChangedURL)
        #expect(didScheduleWithoutSyncedURL)
        #expect(!didScheduleForSelfSave)
    }

    @Test("A local progress save deposits one credit; an unchanged save deposits none")
    func progressSaveDepositsCreditAndRoundTripIsSkipped() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        var arbiter = SyncedStoreRemoteChangeArbiter()

        #expect(store.syncedStoreSelfSaveCount == 0)
        let didSave = store.updateProgress(
            episodeID: "arbiter-episode",
            podcastID: "https://example.com/arbiter.xml",
            position: 10,
            duration: 600,
            modelContext: context
        )
        #expect(didSave)
        #expect(store.syncedStoreSelfSaveCount == 1)

        // The save's own round-tripped notification is skipped…
        let didScheduleForOwnSave = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: store.syncedStoreSelfSaveCount
        )
        // …while a following remote-shaped change still reloads.
        let didScheduleForRemoteChange = arbiter.shouldScheduleReload(
            changedStoreURL: syncedStoreURL,
            syncedStoreURL: syncedStoreURL,
            selfSaveCount: store.syncedStoreSelfSaveCount
        )
        #expect(!didScheduleForOwnSave)
        #expect(didScheduleForRemoteChange)

        let didSaveUnchanged = store.updateProgress(
            episodeID: "arbiter-episode",
            podcastID: "https://example.com/arbiter.xml",
            position: 10,
            duration: 600,
            modelContext: context
        )
        #expect(!didSaveUnchanged)
        #expect(store.syncedStoreSelfSaveCount == 1)
    }
}
