import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Appearance settings store")
struct AppearanceSettingsStoreTests {
    @Test("Every appearance setting persists under its own key, and the Up Next Tab switch loads alone before the rest")
    func upNextTabPersists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AppearanceSettingsStore()
        store.load(modelContext: context)

        #expect(store.setMode(.dark, modelContext: context))
        #expect(store.setMinimizesTabBarOnScroll(true, modelContext: context))
        #expect(store.setShowsUpNextTab(true, modelContext: context))
        #expect(store.showsUpNextTab)

        let launchStore = AppearanceSettingsStore()
        launchStore.loadShowsUpNextTab(modelContext: ModelContext(container))
        #expect(launchStore.showsUpNextTab)
        #expect(launchStore.mode == .system)
        #expect(!launchStore.minimizesTabBarOnScroll)
        launchStore.load(modelContext: ModelContext(container))
        #expect(launchStore.mode == .dark)
        #expect(launchStore.minimizesTabBarOnScroll)
        #expect(launchStore.showsUpNextTab)

        #expect(store.setShowsUpNextTab(false, modelContext: context))
        let reloadedStore = AppearanceSettingsStore()
        reloadedStore.load(modelContext: ModelContext(container))
        #expect(!reloadedStore.showsUpNextTab)
        #expect(reloadedStore.mode == .dark)
        #expect(reloadedStore.minimizesTabBarOnScroll)
    }

    @Test("Loading after the preference is gone turns the switch off")
    func upNextTabResetsWhenThePreferenceIsGone() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AppearanceSettingsStore()
        store.load(modelContext: context)
        #expect(store.setShowsUpNextTab(true, modelContext: context))

        try context.delete(model: LocalPreferenceRecord.self)
        try context.save()
        store.load(modelContext: context)

        #expect(!store.showsUpNextTab)
    }

    @Test("A failed save keeps the previous values in memory and in storage")
    func failedSaveDoesNotLeak() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = AppearanceSettingsSaveProbe()
        let store = AppearanceSettingsStore(save: probe.save)
        store.load(modelContext: context)
        probe.failsSaves = true

        #expect(!store.setMinimizesTabBarOnScroll(true, modelContext: context))
        #expect(!store.minimizesTabBarOnScroll)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update the tab bar setting") == true)
        #expect(!store.setMode(.dark, modelContext: context))
        #expect(store.mode == .system)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update appearance settings") == true)
        #expect(!store.setShowsUpNextTab(true, modelContext: context))
        #expect(!store.showsUpNextTab)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update the tab bar setting") == true)
        // The seam saw the upserted rows, so each failure came after mutation.
        #expect(probe.pendingChangesAtCall == [true, true, true])

        // A later save of the caller's context must not commit the failed rows.
        try context.save()
        let reloadedAfterFailure = AppearanceSettingsStore()
        reloadedAfterFailure.load(modelContext: ModelContext(container))
        #expect(!reloadedAfterFailure.minimizesTabBarOnScroll)
        #expect(reloadedAfterFailure.mode == .system)
        #expect(!reloadedAfterFailure.showsUpNextTab)

        probe.failsSaves = false
        #expect(store.setMode(.light, modelContext: context))

        #expect(store.lastErrorMessage == nil)
        let reloadedAfterRecovery = AppearanceSettingsStore()
        reloadedAfterRecovery.load(modelContext: ModelContext(container))
        #expect(!reloadedAfterRecovery.minimizesTabBarOnScroll)
        #expect(reloadedAfterRecovery.mode == .light)
        #expect(!reloadedAfterRecovery.showsUpNextTab)
    }
}

private final class AppearanceSettingsSaveProbe {
    var failsSaves = false
    private(set) var pendingChangesAtCall: [Bool] = []

    func save(_ context: ModelContext) throws {
        pendingChangesAtCall.append(context.hasChanges)
        if failsSaves {
            throw AppearanceSettingsSaveFailure()
        }
        try context.save()
    }
}

private struct AppearanceSettingsSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Injected save failure."
    }
}
