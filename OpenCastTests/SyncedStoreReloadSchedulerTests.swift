import Testing
@testable import OpenCast

@MainActor
struct SyncedStoreReloadSchedulerTests {
    @Test("CloudKit batches during hydration queue one follow-up without cancelling it")
    func batchesDoNotCancelActiveHydration() async {
        let scheduler = SyncedStoreReloadScheduler(debounce: .zero)
        let started = AsyncTestGate()
        let finish = AsyncTestGate()
        var calls = 0
        var active = 0
        var maximumActive = 0
        var wasCancelled = false
        let reload: @MainActor () async -> Void = {
            calls += 1
            active += 1
            maximumActive = max(maximumActive, active)
            if calls == 1 {
                await started.release()
                await finish.wait()
            }
            wasCancelled = wasCancelled || Task.isCancelled
            active -= 1
        }

        scheduler.schedule(reload)
        await started.wait()
        for _ in 0..<3 { scheduler.schedule(reload) }
        await finish.release()
        await scheduler.waitUntilIdle()

        #expect(calls == 2)
        #expect(maximumActive == 1)
        #expect(!wasCancelled)
    }

    @Test("Import batches share a cumulative banner identity and count unique feeds")
    func importedSubscriptionBatchesMerge() {
        let first = Set((0..<25).map { "https://example.com/\($0).xml" })
        let next = Set((20..<34).map { "https://example.com/\($0).xml" })
        let banner = ImportedSubscriptionsNotification(id: 7, feedURLStrings: first)
        let updated = banner.merging(feedURLStrings: next)

        #expect(updated.id == banner.id)
        #expect(updated.feedCount == 34)
        #expect(updated.merging(feedURLStrings: next) == updated)
    }
}
