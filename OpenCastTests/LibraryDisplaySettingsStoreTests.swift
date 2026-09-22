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

    @Test("Preference keys stay stable")
    func preferenceKeysStayStable() {
        #expect(LibraryDisplaySettingsStore.layoutPreferenceKey == layoutKey)
        #expect(LibraryDisplaySettingsStore.sortOrderPreferenceKey == sortOrderKey)
        #expect(LibraryDisplaySettingsStore.showsNewEpisodeBadgesPreferenceKey == badgesKey)
    }

    @Test("Settings default to Automatic, Title and badges on")
    func defaultsWithoutStoredRows() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = LibraryDisplaySettingsStore()

        store.load(modelContext: ModelContext(container))

        #expect(store.layout == .automatic)
        #expect(store.sortOrder == .title)
        #expect(store.showsNewEpisodeBadges)
        #expect(store.lastErrorMessage == nil)
    }

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

        // A second choice updates the existing row instead of adding one.
        #expect(store.setLayout(.list, modelContext: context))
        #expect(store.setShowsNewEpisodeBadges(true, modelContext: context))
        #expect(try storedValues(forKey: layoutKey, in: container) == ["list"])
        #expect(try storedValues(forKey: badgesKey, in: container) == ["true"])
        #expect(reloadedStore(from: container).layout == .list)
    }

    @Test("Preferences saved to disk survive reopening the store file")
    func diskBackedPreferencesSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "LibraryDisplaySettingsStoreTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let storeURL = directory.appending(path: "local.sqlite")

        try savePreferencesToDisk(at: storeURL)
        #expect(FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))

        // Nothing is seeded here: the reopened container only has what the
        // released one wrote to disk.
        let reopenedContainer = try Self.makeDiskBackedContainer(url: storeURL)
        let store = LibraryDisplaySettingsStore()
        store.load(modelContext: ModelContext(reopenedContainer))

        #expect(store.layout == .grid)
        #expect(store.sortOrder == .recentEpisodes)
        #expect(!store.showsNewEpisodeBadges)
        #expect(store.lastErrorMessage == nil)
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

    @Test("Choosing the current value skips the save")
    func noOpSettersSkipSave() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)
        store.load(modelContext: context)

        #expect(store.setLayout(.automatic, modelContext: context))
        #expect(store.setSortOrder(.title, modelContext: context))
        #expect(store.setShowsNewEpisodeBadges(true, modelContext: context))
        #expect(probe.callCount == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalPreferenceRecord>()).isEmpty)

        #expect(store.setLayout(.grid, modelContext: context))
        #expect(store.setLayout(.grid, modelContext: context))
        #expect(probe.callCount == 1)
    }

    @Test("Unknown stored values load as defaults without rewriting storage")
    func unknownStoredValuesLoadAsDefaults() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(LocalPreferenceRecord(key: layoutKey, value: "sideways"))
        context.insert(LocalPreferenceRecord(key: sortOrderKey, value: "loudest"))
        context.insert(LocalPreferenceRecord(key: badgesKey, value: "maybe"))
        try context.save()
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)

        store.load(modelContext: context)

        #expect(store.layout == .automatic)
        #expect(store.sortOrder == .title)
        #expect(store.showsNewEpisodeBadges)
        #expect(store.lastErrorMessage == nil)
        #expect(probe.callCount == 0)
        #expect(try storedValues(forKey: layoutKey, in: container) == ["sideways"])
        #expect(try storedValues(forKey: sortOrderKey, in: container) == ["loudest"])
        #expect(try storedValues(forKey: badgesKey, in: container) == ["maybe"])
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

        // The caller still owns its pending edits and commits them itself;
        // the failed sort order doesn't ride along.
        try mainContext.save()
        #expect(try ModelContext(container).fetch(FetchDescriptor<SubscriptionRecord>()).count == 1)
        #expect(try storedValues(forKey: "test.pendingPreference", in: container) == ["pending"])
        #expect(try storedValues(forKey: sortOrderKey, in: container).isEmpty)
    }

    @Test("A later successful save or load clears the error")
    func laterSuccessClearsError() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = LibraryDisplaySettingsSaveProbe()
        let store = LibraryDisplaySettingsStore(save: probe.save)
        store.load(modelContext: context)
        probe.failsSaves = true

        #expect(!store.setLayout(.grid, modelContext: context))
        #expect(store.lastErrorMessage != nil)
        probe.failsSaves = false
        #expect(store.setLayout(.grid, modelContext: context))
        #expect(store.lastErrorMessage == nil)
        #expect(store.layout == .grid)

        probe.failsSaves = true
        #expect(!store.setSortOrder(.recentEpisodes, modelContext: context))
        #expect(store.lastErrorMessage != nil)
        store.load(modelContext: context)
        #expect(store.lastErrorMessage == nil)
        #expect(store.layout == .grid)
        #expect(store.sortOrder == .title)
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

        // DataNukeRunner deletes every LocalPreferenceRecord row; the app
        // model then reloads the same settings store.
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

    /// Saves every preference through a container and store released on
    /// return, so a reopen can only read what reached the file.
    private func savePreferencesToDisk(at url: URL) throws {
        let container = try Self.makeDiskBackedContainer(url: url)
        let context = ModelContext(container)
        let store = LibraryDisplaySettingsStore()
        store.load(modelContext: context)

        #expect(store.setLayout(.grid, modelContext: context))
        #expect(store.setSortOrder(.recentEpisodes, modelContext: context))
        #expect(store.setShowsNewEpisodeBadges(false, modelContext: context))
    }

    /// The app's local-store configuration at a temporary URL, with CloudKit
    /// off; never the real app database.
    private static func makeDiskBackedContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            OpenCastModelContainerFactory.localConfigurationName,
            schema: OpenCastModelContainerFactory.localSchema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: OpenCastModelContainerFactory.localSchema,
            configurations: [configuration]
        )
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

/// Stands in for the store's save seam. The store calls it after the upsert
/// or delete has already mutated the isolated context, so a failing call
/// exercises failure after mutation.
private final class LibraryDisplaySettingsSaveProbe {
    var failsSaves = false
    private(set) var callCount = 0
    private(set) var pendingChangesAtCall: [Bool] = []

    func save(_ context: ModelContext) throws {
        callCount += 1
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
