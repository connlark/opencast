import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Appearance settings store")
struct AppearanceSettingsStoreTests {
    @Test("Appearance defaults to system")
    func appearanceDefaultsToSystem() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AppearanceSettingsStore()

        store.load(modelContext: context)

        #expect(store.mode == .system)
    }

    @Test("Appearance mode persists")
    func appearanceModePersists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AppearanceSettingsStore()

        store.load(modelContext: context)
        store.setMode(.dark, modelContext: context)

        let reloadedStore = AppearanceSettingsStore()
        reloadedStore.load(modelContext: context)

        #expect(store.mode == .dark)
        #expect(reloadedStore.mode == .dark)
    }

    @Test("Tab bar minimizing defaults to off")
    func tabBarMinimizingDefaultsToOff() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AppearanceSettingsStore()

        store.load(modelContext: context)

        #expect(!store.minimizesTabBarOnScroll)
    }

    @Test("Tab bar minimizing persists without touching the appearance mode")
    func tabBarMinimizingPersists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AppearanceSettingsStore()

        store.load(modelContext: context)
        store.setMinimizesTabBarOnScroll(true, modelContext: context)

        let reloadedStore = AppearanceSettingsStore()
        reloadedStore.load(modelContext: context)

        #expect(store.minimizesTabBarOnScroll)
        #expect(reloadedStore.minimizesTabBarOnScroll)
        #expect(reloadedStore.mode == .system)
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
        // The seam saw the upserted rows, so each failure came after mutation.
        #expect(probe.pendingChangesAtCall == [true, true])

        // A later save of the caller's context must not commit the failed rows.
        try context.save()
        let reloadedAfterFailure = AppearanceSettingsStore()
        reloadedAfterFailure.load(modelContext: ModelContext(container))
        #expect(!reloadedAfterFailure.minimizesTabBarOnScroll)
        #expect(reloadedAfterFailure.mode == .system)

        probe.failsSaves = false
        #expect(store.setMode(.light, modelContext: context))

        #expect(store.lastErrorMessage == nil)
        let reloadedAfterRecovery = AppearanceSettingsStore()
        reloadedAfterRecovery.load(modelContext: ModelContext(container))
        #expect(!reloadedAfterRecovery.minimizesTabBarOnScroll)
        #expect(reloadedAfterRecovery.mode == .light)
    }
}

/// Stands in for the store's save seam. The store calls it after the upsert
/// has already mutated the isolated context, so a failing call exercises
/// failure after mutation.
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
