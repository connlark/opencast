import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Inbox episode list settings store")
struct InboxEpisodeListSettingsStoreTests {
    // Stored keys are a storage contract; the literals pin them.
    private let filterKey = "inbox.filter"
    private let hidesQueuedKey = "inbox.hidesQueuedEpisodes"

    @Test("Preference keys stay stable")
    func preferenceKeysStayStable() {
        #expect(InboxEpisodeListSettingsStore.filterPreferenceKey == filterKey)
        #expect(InboxEpisodeListSettingsStore.hidesQueuedEpisodesPreferenceKey == hidesQueuedKey)
    }

    @Test("Settings default to All Episodes with Up Next shown")
    func defaultsWithoutStoredRows() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = InboxEpisodeListSettingsStore()

        store.load(modelContext: ModelContext(container))

        #expect(store.filter == .all)
        #expect(!store.hidesQueuedEpisodes)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Both settings persist and reload in a fresh store")
    func settersPersistAndReload() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = InboxEpisodeListSettingsStore()
        store.load(modelContext: context)

        #expect(store.setFilter(.unplayed, modelContext: context))
        #expect(store.setHidesQueuedEpisodes(true, modelContext: context))

        #expect(store.filter == .unplayed)
        #expect(store.hidesQueuedEpisodes)
        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: filterKey, in: container) == ["unplayed"])
        #expect(try storedValues(forKey: hidesQueuedKey, in: container) == ["true"])

        let reloaded = reloadedStore(from: container)
        #expect(reloaded.filter == .unplayed)
        #expect(reloaded.hidesQueuedEpisodes)

        // A second choice updates the existing row instead of adding one.
        #expect(store.setFilter(.downloaded, modelContext: context))
        #expect(store.setHidesQueuedEpisodes(false, modelContext: context))
        #expect(try storedValues(forKey: filterKey, in: container) == ["downloaded"])
        #expect(try storedValues(forKey: hidesQueuedKey, in: container) == ["false"])
        #expect(reloadedStore(from: container).filter == .downloaded)
        #expect(!reloadedStore(from: container).hidesQueuedEpisodes)
    }

    @Test("Unknown stored values load as defaults without rewriting storage")
    func unknownStoredValuesLoadAsDefaults() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(LocalPreferenceRecord(key: filterKey, value: "queued"))
        context.insert(LocalPreferenceRecord(key: hidesQueuedKey, value: "maybe"))
        try context.save()
        let probe = InboxEpisodeListSettingsSaveProbe()
        let store = InboxEpisodeListSettingsStore(save: probe.save)

        store.load(modelContext: context)

        #expect(store.filter == .all)
        #expect(!store.hidesQueuedEpisodes)
        #expect(store.lastErrorMessage == nil)
        #expect(probe.callCount == 0)
        #expect(try storedValues(forKey: filterKey, in: container) == ["queued"])
        #expect(try storedValues(forKey: hidesQueuedKey, in: container) == ["maybe"])
    }

    @Test("Choosing the current value skips the save")
    func noOpSettersSkipSave() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = InboxEpisodeListSettingsSaveProbe()
        let store = InboxEpisodeListSettingsStore(save: probe.save)
        store.load(modelContext: context)

        #expect(store.setFilter(.all, modelContext: context))
        #expect(store.setHidesQueuedEpisodes(false, modelContext: context))
        #expect(probe.callCount == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalPreferenceRecord>()).isEmpty)

        #expect(store.setFilter(.played, modelContext: context))
        #expect(store.setFilter(.played, modelContext: context))
        #expect(store.setHidesQueuedEpisodes(true, modelContext: context))
        #expect(store.setHidesQueuedEpisodes(true, modelContext: context))
        #expect(probe.callCount == 2)
    }

    @Test("A failed save keeps the published values and reports, then recovers")
    func failedSaveKeepsPublishedValues() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = InboxEpisodeListSettingsSaveProbe()
        let store = InboxEpisodeListSettingsStore(save: probe.save)
        store.load(modelContext: context)
        #expect(store.setFilter(.inProgress, modelContext: context))
        probe.failsSaves = true

        #expect(!store.setFilter(.played, modelContext: context))
        #expect(store.filter == .inProgress)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Inbox filter") == true)
        #expect(!store.setHidesQueuedEpisodes(true, modelContext: context))
        #expect(!store.hidesQueuedEpisodes)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Hide Up Next Episodes") == true)
        // The seam saw the upserted rows, so each failure came after mutation.
        #expect(probe.pendingChangesAtCall == [true, true, true])

        probe.failsSaves = false
        #expect(store.setHidesQueuedEpisodes(true, modelContext: context))

        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: filterKey, in: container) == ["inProgress"])
        #expect(try storedValues(forKey: hidesQueuedKey, in: container) == ["true"])
        let reloaded = reloadedStore(from: container)
        #expect(reloaded.filter == .inProgress)
        #expect(reloaded.hidesQueuedEpisodes)
    }

    @Test("Loading after a data reset restores the defaults")
    func dataResetRestoresDefaults() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = InboxEpisodeListSettingsStore()
        store.load(modelContext: context)
        #expect(store.setFilter(.downloaded, modelContext: context))
        #expect(store.setHidesQueuedEpisodes(true, modelContext: context))

        // DataNukeRunner deletes every LocalPreferenceRecord row; the app
        // model then reloads the same settings store.
        for record in try context.fetch(FetchDescriptor<LocalPreferenceRecord>()) {
            context.delete(record)
        }
        try context.save()
        store.load(modelContext: context)

        #expect(store.filter == .all)
        #expect(!store.hidesQueuedEpisodes)
        #expect(store.lastErrorMessage == nil)
    }

    private func storedValues(forKey key: String, in container: ModelContainer) throws -> [String] {
        try ModelContext(container)
            .fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == key }
            .map(\.value)
    }

    private func reloadedStore(from container: ModelContainer) -> InboxEpisodeListSettingsStore {
        let store = InboxEpisodeListSettingsStore()
        store.load(modelContext: ModelContext(container))
        return store
    }
}

/// Stands in for the store's save seam. The store calls it after the upsert
/// has already mutated the isolated context, so a failing call exercises
/// failure after mutation.
private final class InboxEpisodeListSettingsSaveProbe {
    var failsSaves = false
    private(set) var callCount = 0
    private(set) var pendingChangesAtCall: [Bool] = []

    func save(_ context: ModelContext) throws {
        callCount += 1
        pendingChangesAtCall.append(context.hasChanges)
        if failsSaves {
            throw InboxEpisodeListSettingsSaveFailure()
        }
        try context.save()
    }
}

private struct InboxEpisodeListSettingsSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated preference save failure"
    }
}
