import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Notification promo banner store")
struct NotificationPromoBannerStoreTests {
    @Test("Absent preference leaves banner unresolved")
    func absentPreferenceLeavesBannerUnresolved() throws {
        let context = try makeContext()
        let store = NotificationPromoBannerStore()

        store.load(modelContext: context)

        #expect(!store.isResolved)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Mark resolved persists local preference")
    func markResolvedPersistsLocalPreference() throws {
        let context = try makeContext()
        let store = NotificationPromoBannerStore()

        #expect(store.markResolved(modelContext: context))

        let reloadedStore = NotificationPromoBannerStore()
        reloadedStore.load(modelContext: context)
        #expect(reloadedStore.isResolved)
        #expect(try LocalPreferenceRecord.preference(
            forKey: NotificationPromoBannerStore.resolvedPreferenceKey,
            modelContext: context
        )?.value == "true")
    }

    @Test("Reset after data nuke clears runtime state")
    func resetAfterDataNukeClearsRuntimeState() throws {
        let context = try makeContext()
        let store = NotificationPromoBannerStore()
        #expect(store.markResolved(modelContext: context))

        store.resetAfterDataNuke()

        #expect(!store.isResolved)
        #expect(store.lastErrorMessage == nil)
    }

    private func makeContext() throws -> ModelContext {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        return ModelContext(container)
    }
}
