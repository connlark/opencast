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
}
