import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Library display settings store")
struct LibraryDisplaySettingsStoreTests {
    // Stored keys are a storage contract; the literals pin them.
    private let layoutKey = "library.layout"
    private let sortOrderKey = "library.sortOrder"
    private let badgesKey = "library.showsNewEpisodeBadges"

    @Test("Every setting persists and reloads in a fresh store")
    func settersPersistAndReload() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryDisplaySettingsStore()
        store.load(modelContext: context)

        #expect(store.setLayout(.grid, modelContext: context))
        #expect(store.setSortOrder(.recentEpisodes, modelContext: context))
        #expect(store.setShowsNewEpisodeBadges(false, modelContext: context))

        #expect(store.layout == .grid)
        #expect(store.sortOrder == .recentEpisodes)
        #expect(!store.showsNewEpisodeBadges)
        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: layoutKey, in: container) == ["grid"])
        #expect(try storedValues(forKey: sortOrderKey, in: container) == ["recentEpisodes"])
        #expect(try storedValues(forKey: badgesKey, in: container) == ["false"])

        let reloaded = reloadedStore(from: container)
        #expect(reloaded.layout == .grid)
        #expect(reloaded.sortOrder == .recentEpisodes)
        #expect(!reloaded.showsNewEpisodeBadges)

        #expect(store.setLayout(.list, modelContext: context))
        #expect(store.setShowsNewEpisodeBadges(true, modelContext: context))
        #expect(try storedValues(forKey: layoutKey, in: container) == ["list"])
        #expect(try storedValues(forKey: badgesKey, in: container) == ["true"])
        #expect(reloadedStore(from: container).layout == .list)
    }

    @Test("Automatic deletes every layout row, including older duplicates")
    func automaticDeletesEveryLayoutRow() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(LocalPreferenceRecord(
            key: layoutKey,
            value: "list",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        ))
        context.insert(LocalPreferenceRecord(
            key: layoutKey,
            value: "grid",
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        ))
        context.insert(LocalPreferenceRecord(key: sortOrderKey, value: "recentEpisodes"))
        try context.save()
        let store = LibraryDisplaySettingsStore()
        store.load(modelContext: context)
        #expect(store.layout == .grid)

        #expect(store.setLayout(.automatic, modelContext: context))

        #expect(store.layout == .automatic)
        #expect(try storedValues(forKey: layoutKey, in: container).isEmpty)
        #expect(try storedValues(forKey: sortOrderKey, in: container) == ["recentEpisodes"])
        #expect(reloadedStore(from: container).layout == .automatic)
    }

    @Test("A failed first save keeps the default and never reaches storage")
    func failedInsertDoesNotLeak() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)
        store.load(modelContext: context)
        probe.failsSaves = true

        #expect(!store.setLayout(.grid, modelContext: context))
        #expect(store.layout == .automatic)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Library layout") == true)
        #expect(!store.setShowsNewEpisodeBadges(false, modelContext: context))
        #expect(store.showsNewEpisodeBadges)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update new episode badges") == true)
        // The seam saw the inserted rows, so each failure came after mutation.
        #expect(probe.pendingChangesAtCall == [true, true])

        probe.failsSaves = false
        #expect(store.setSortOrder(.recentEpisodes, modelContext: context))

        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: layoutKey, in: container).isEmpty)
        #expect(try storedValues(forKey: badgesKey, in: container).isEmpty)
        #expect(try storedValues(forKey: sortOrderKey, in: container) == ["recentEpisodes"])
        let reloaded = reloadedStore(from: container)
        #expect(reloaded.layout == .automatic)
        #expect(reloaded.sortOrder == .recentEpisodes)
        #expect(reloaded.showsNewEpisodeBadges)
    }

    @Test("A failed update keeps the previous choice in memory and in storage")
    func failedUpdateDoesNotLeak() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)
        store.load(modelContext: context)
        #expect(store.setLayout(.list, modelContext: context))
        #expect(store.setSortOrder(.recentEpisodes, modelContext: context))
        probe.failsSaves = true

        #expect(!store.setLayout(.grid, modelContext: context))
        #expect(store.layout == .list)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Library layout") == true)
        #expect(!store.setSortOrder(.title, modelContext: context))
        #expect(store.sortOrder == .recentEpisodes)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Library sort order") == true)
        #expect(probe.pendingChangesAtCall == [true, true, true, true])

        probe.failsSaves = false
        #expect(store.setShowsNewEpisodeBadges(false, modelContext: context))

        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: layoutKey, in: container) == ["list"])
        #expect(try storedValues(forKey: sortOrderKey, in: container) == ["recentEpisodes"])
        #expect(try storedValues(forKey: badgesKey, in: container) == ["false"])
        let reloaded = reloadedStore(from: container)
        #expect(reloaded.layout == .list)
        #expect(reloaded.sortOrder == .recentEpisodes)
        #expect(!reloaded.showsNewEpisodeBadges)
    }

    @Test("A failed switch to Automatic keeps the explicit layout row")
    func failedDeleteDoesNotLeak() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)
        store.load(modelContext: context)
        #expect(store.setLayout(.grid, modelContext: context))
        probe.failsSaves = true

        #expect(!store.setLayout(.automatic, modelContext: context))
        #expect(store.layout == .grid)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Library layout") == true)
        #expect(probe.pendingChangesAtCall == [true, true])

        probe.failsSaves = false
        #expect(store.setSortOrder(.recentEpisodes, modelContext: context))

        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: layoutKey, in: container) == ["grid"])
        #expect(reloadedStore(from: container).layout == .grid)
    }

    @Test("Preference saves neither commit nor discard another context's pending changes")
    func preferenceSavesLeaveOtherContextsAlone() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let mainContext = ModelContext(container)
        mainContext.autosaveEnabled = false
        mainContext.insert(SubscriptionRecord(feedURL: "https://example.com/pending.xml", title: "Pending Show"))
        mainContext.insert(LocalPreferenceRecord(key: "test.pendingPreference", value: "pending"))
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)
        store.load(modelContext: mainContext)

        #expect(store.setLayout(.grid, modelContext: mainContext))
        probe.failsSaves = true
        #expect(!store.setSortOrder(.recentEpisodes, modelContext: mainContext))

        #expect(mainContext.hasChanges)
        #expect(mainContext.insertedModelsArray.count == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SubscriptionRecord>()).isEmpty)
        #expect(try storedValues(forKey: "test.pendingPreference", in: container).isEmpty)
        #expect(try storedValues(forKey: layoutKey, in: container) == ["grid"])

        try mainContext.save()
        #expect(try ModelContext(container).fetch(FetchDescriptor<SubscriptionRecord>()).count == 1)
        #expect(try storedValues(forKey: "test.pendingPreference", in: container) == ["pending"])
        #expect(try storedValues(forKey: sortOrderKey, in: container).isEmpty)
    }

    @Test("Loading after a data reset restores the defaults")
    func dataResetRestoresDefaults() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryDisplaySettingsStore()
        store.load(modelContext: context)
        #expect(store.setLayout(.list, modelContext: context))
        #expect(store.setSortOrder(.recentEpisodes, modelContext: context))
        #expect(store.setShowsNewEpisodeBadges(false, modelContext: context))

        for record in try context.fetch(FetchDescriptor<LocalPreferenceRecord>()) {
            context.delete(record)
        }
        try context.save()
        store.load(modelContext: context)

        #expect(store.layout == .automatic)
        #expect(store.sortOrder == .title)
        #expect(store.showsNewEpisodeBadges)
        #expect(store.lastErrorMessage == nil)
    }

    private func storedValues(forKey key: String, in container: ModelContainer) throws -> [String] {
        try ModelContext(container)
            .fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == key }
            .map(\.value)
    }

    private func reloadedStore(from container: ModelContainer) -> LibraryDisplaySettingsStore {
        let store = LibraryDisplaySettingsStore()
        store.load(modelContext: ModelContext(container))
        return store
    }
}

private final class LibraryDisplaySettingsSaveProbe {
    var failsSaves = false
    private(set) var pendingChangesAtCall: [Bool] = []

    func save(_ context: ModelContext) throws {
        pendingChangesAtCall.append(context.hasChanges)
        if failsSaves {
            throw LibraryDisplaySettingsSaveFailure()
        }
        try context.save()
    }
}

private struct LibraryDisplaySettingsSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated preference save failure"
    }
}
