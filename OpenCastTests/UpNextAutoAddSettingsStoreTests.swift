import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Up Next auto add settings store")
struct UpNextAutoAddSettingsStoreTests {
    private let showA = "https://example.com/a.xml"
    private let showB = "https://example.com/b.xml"
    private let showC = "https://example.com/c.xml"

    @Test("Preference keys and stored values stay stable")
    func preferenceKeysStayStable() {
        // Stored keys and values are a storage contract; the literals pin them.
        #expect(UpNextAutoAddSettingsStore.watermarkKeyPrefix == "upNext.autoAddWatermark.")
        #expect(UpNextAutoAddSettingsStore.limitPreferenceKey == "upNext.autoAddLimit")
        #expect(UpNextAutoAddSettingsStore.limitReachedActionPreferenceKey == "upNext.autoAddLimitReached")
        #expect(UpNextAutoAddLimit.allCases.map(\.rawValue) == [10, 20, 50, 100, 200, 500, 1000])
        #expect(UpNextAutoAddLimit.standard == .oneHundred)
        #expect(UpNextAutoAddLimitReachedAction.allCases.map(\.rawValue) == ["stopAdding", "addToTopOnly"])
    }

    @Test("Limits and rules title themselves")
    func titles() {
        #expect(UpNextAutoAddLimit.ten.title == "10 Episodes")
        #expect(UpNextAutoAddLimit.oneHundred.title == "100 Episodes")
        #expect(UpNextAutoAddLimit.oneThousand.title == "1,000 Episodes")
        #expect(UpNextAutoAddLimitReachedAction.stopAdding.title == "Stop Adding New Episodes")
        #expect(UpNextAutoAddLimitReachedAction.addToTopOnly.title == "Only Add to Top")
        #expect(UpNextAutoAddLimitReachedAction.stopAdding.shortTitle == "Stop Adding")
        #expect(UpNextAutoAddLimitReachedAction.addToTopOnly.shortTitle == "Only Add to Top")
    }

    @Test("Defaults: 100 episodes, Stop Adding New Episodes, no watermarks")
    func defaultsWithoutStoredRows() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = UpNextAutoAddSettingsStore()

        store.load(modelContext: ModelContext(container))

        #expect(store.limit == .oneHundred)
        #expect(store.limitReachedAction == .stopAdding)
        #expect(store.watermark(forPodcastID: showA) == nil)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Load reads each key")
    func loadReadsEachKey() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let watermark = Date(timeIntervalSinceReferenceDate: 783_456_789.123_456_7)
        for (key, value) in [
            (UpNextAutoAddSettingsStore.limitPreferenceKey, "500"),
            (UpNextAutoAddSettingsStore.limitReachedActionPreferenceKey, "addToTopOnly"),
            (UpNextAutoAddSettingsStore.watermarkKeyPrefix + showA, UpNextAutoAddSettingsStore.encodeWatermark(watermark)),
            (UpNextAutoAddSettingsStore.watermarkKeyPrefix + showB, UpNextAutoAddSettingsStore.encodeWatermark(.distantPast)),
        ] {
            context.insert(LocalPreferenceRecord(key: key, value: value))
        }
        try context.save()

        let store = reloadedStore(from: container)

        #expect(store.limit == .fiveHundred)
        #expect(store.limitReachedAction == .addToTopOnly)
        #expect(store.watermark(forPodcastID: showA) == watermark)
        #expect(store.watermark(forPodcastID: showB) == .distantPast)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Every setting round-trips through a fresh store, with the exact watermark")
    func settingsRoundTrip() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = UpNextAutoAddSettingsStore()
        store.load(modelContext: context)
        let watermark = Date(timeIntervalSinceReferenceDate: 783_456_789.123_456_7)

        #expect(store.setLimit(.ten, modelContext: context))
        #expect(store.setLimitReachedAction(.addToTopOnly, modelContext: context))
        #expect(store.setWatermark(watermark, forPodcastID: showA, modelContext: context))
        #expect(store.limit == .ten)
        #expect(store.limitReachedAction == .addToTopOnly)
        #expect(store.watermark(forPodcastID: showA) == watermark)

        let reloaded = reloadedStore(from: container)
        #expect(reloaded.limit == .ten)
        #expect(reloaded.limitReachedAction == .addToTopOnly)
        #expect(reloaded.watermark(forPodcastID: showA) == watermark)
        #expect(reloaded.watermark(forPodcastID: showB) == nil)

        let advanced = watermark.addingTimeInterval(86_400.5)
        #expect(store.setWatermark(advanced, forPodcastID: showA, modelContext: context))
        #expect(reloadedStore(from: container).watermark(forPodcastID: showA) == advanced)
        #expect(try storedValues(forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + showA, in: container).count == 1)
    }

    @Test("Unknown stored values load as defaults")
    func unknownStoredValuesFallBack() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for (key, value) in [
            (UpNextAutoAddSettingsStore.limitPreferenceKey, "7"),
            (UpNextAutoAddSettingsStore.limitReachedActionPreferenceKey, "stopEverything"),
            (UpNextAutoAddSettingsStore.watermarkKeyPrefix + showA, "yesterday"),
            (UpNextAutoAddSettingsStore.watermarkKeyPrefix, "0"),
        ] {
            context.insert(LocalPreferenceRecord(key: key, value: value))
        }
        try context.save()

        let store = reloadedStore(from: container)

        #expect(store.limit == .standard)
        #expect(store.limitReachedAction == .stopAdding)
        #expect(store.watermark(forPodcastID: showA) == nil)
        #expect(store.watermark(forPodcastID: "") == nil)
        #expect(store.lastErrorMessage == nil)

        context.insert(LocalPreferenceRecord(key: UpNextAutoAddSettingsStore.limitPreferenceKey, value: "ten"))
        try context.save()
        #expect(reloadedStore(from: container).limit == .standard)
    }

    @Test("The newest duplicate row wins")
    func newestDuplicateWins() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let key = UpNextAutoAddSettingsStore.limitPreferenceKey
        context.insert(LocalPreferenceRecord(key: key, value: "20", updatedAt: Date(timeIntervalSinceReferenceDate: 100)))
        context.insert(LocalPreferenceRecord(key: key, value: "200", updatedAt: Date(timeIntervalSinceReferenceDate: 200)))
        try context.save()

        #expect(reloadedStore(from: container).limit == .twoHundred)
    }

    @Test("Removing a show's watermark deletes only its row, and a reload shows none")
    func removeWatermarkIsScoped() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = UpNextAutoAddSettingsStore()
        store.load(modelContext: context)
        for show in [showA, showB] {
            #expect(store.setWatermark(.distantPast, forPodcastID: show, modelContext: context))
        }
        #expect(store.setLimit(.fifty, modelContext: context))

        #expect(store.removeWatermark(forPodcastID: showA, modelContext: context))

        for reloaded in [store, reloadedStore(from: container)] {
            #expect(reloaded.watermark(forPodcastID: showA) == nil)
            #expect(reloaded.watermark(forPodcastID: showB) == .distantPast)
            #expect(reloaded.limit == .fifty)
        }
        #expect(try storedValues(forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + showA, in: container).isEmpty)
        #expect(try storedValues(forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + showB, in: container).count == 1)
        #expect(store.removeWatermark(forPodcastID: showA, modelContext: context))
    }

    @Test("Removing a watermark with no stored row saves nothing and succeeds, even while saves fail")
    func removingAMissingWatermarkSkipsTheSave() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = UpNextAutoAddSettingsSaveProbe()
        let store = UpNextAutoAddSettingsStore(save: probe.save)
        store.load(modelContext: context)
        probe.failsSaves = true

        #expect(store.removeWatermark(forPodcastID: showA, modelContext: context))

        #expect(probe.callCount == 0)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Removing several shows' watermarks deletes only their rows in one save and keeps an unread error")
    func removeWatermarksIsScopedAndKeepsErrorMessage() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = UpNextAutoAddSettingsSaveProbe()
        let store = UpNextAutoAddSettingsStore(save: probe.save)
        store.load(modelContext: context)
        for show in [showA, showB, showC] {
            #expect(store.setWatermark(.distantPast, forPodcastID: show, modelContext: context))
        }
        probe.failsSaves = true
        #expect(!store.setLimit(.ten, modelContext: context))
        probe.failsSaves = false
        let savesBefore = probe.callCount
        #expect(store.watermarkPodcastIDs == [showA, showB, showC])

        #expect(store.removeWatermarks(forPodcastIDs: [showA, showB], modelContext: context))

        #expect(probe.callCount == savesBefore + 1)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Auto Add Limit") == true)
        for reloaded in [store, reloadedStore(from: container)] {
            #expect(reloaded.watermarkPodcastIDs == [showC])
            #expect(reloaded.watermark(forPodcastID: showC) == .distantPast)
        }
        #expect(try storedValues(forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + showA, in: container).isEmpty)
        #expect(try storedValues(forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + showB, in: container).isEmpty)
        #expect(try storedValues(forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + showC, in: container).count == 1)
    }

    @Test("Removing no shows, or shows without a stored row, saves nothing and succeeds")
    func removeWatermarksWithNothingToDeleteSkipsTheSave() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = UpNextAutoAddSettingsSaveProbe()
        let store = UpNextAutoAddSettingsStore(save: probe.save)
        store.load(modelContext: context)
        probe.failsSaves = true

        #expect(store.removeWatermarks(forPodcastIDs: [], modelContext: context))
        #expect(store.removeWatermarks(forPodcastIDs: [showA, showB], modelContext: context))

        #expect(probe.callCount == 0)
        #expect(store.lastErrorMessage == nil)
        #expect(store.watermarkPodcastIDs.isEmpty)
    }

    @Test("A watermark save leaves an unread error message alone")
    func watermarkSaveKeepsErrorMessage() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = UpNextAutoAddSettingsSaveProbe()
        let store = UpNextAutoAddSettingsStore(save: probe.save)
        store.load(modelContext: context)
        probe.failsSaves = true
        #expect(!store.setLimit(.ten, modelContext: context))
        probe.failsSaves = false

        #expect(store.setWatermark(.now, forPodcastID: showA, modelContext: context))

        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Auto Add Limit") == true)
    }

    @Test("A failed save leaves every published value alone, in memory and storage, with a message")
    func failedSaveKeepsPreviousValues() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = UpNextAutoAddSettingsSaveProbe()
        let store = UpNextAutoAddSettingsStore(save: probe.save)
        store.load(modelContext: context)
        let watermark = Date(timeIntervalSinceReferenceDate: 783_456_789)
        #expect(store.setWatermark(watermark, forPodcastID: showA, modelContext: context))
        probe.failsSaves = true

        #expect(!store.setLimit(.twenty, modelContext: context))
        #expect(store.limit == .standard)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Auto Add Limit: ") == true)
        #expect(!store.setLimitReachedAction(.addToTopOnly, modelContext: context))
        #expect(store.limitReachedAction == .stopAdding)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update If Limit Reached: ") == true)
        #expect(!store.setWatermark(watermark.addingTimeInterval(60), forPodcastID: showA, modelContext: context))
        #expect(store.watermark(forPodcastID: showA) == watermark)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to record new episodes for Up Next: ") == true)
        #expect(!store.removeWatermark(forPodcastID: showA, modelContext: context))
        #expect(store.watermark(forPodcastID: showA) == watermark)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to remove this show's Up Next settings: ") == true)
        #expect(store.lastErrorMessage?.contains("Simulated preference save failure") == true)
        #expect(!store.removeWatermarks(forPodcastIDs: [showA], modelContext: context))
        #expect(store.watermark(forPodcastID: showA) == watermark)
        #expect(store.watermarkPodcastIDs == [showA])
        #expect(store.lastErrorMessage?.hasPrefix("Unable to remove old Up Next settings: ") == true)
        #expect(probe.pendingChangesAtCall.allSatisfy { $0 })

        let reloaded = reloadedStore(from: container)
        #expect(reloaded.limit == .standard)
        #expect(reloaded.limitReachedAction == .stopAdding)
        #expect(reloaded.watermark(forPodcastID: showA) == watermark)

        probe.failsSaves = false
        #expect(store.setLimit(.twenty, modelContext: context))
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Unchanged values skip the save")
    func noOpSettersSkipSave() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = UpNextAutoAddSettingsSaveProbe()
        let store = UpNextAutoAddSettingsStore(save: probe.save)
        store.load(modelContext: context)

        #expect(store.setLimit(.standard, modelContext: context))
        #expect(store.setLimitReachedAction(.stopAdding, modelContext: context))
        #expect(probe.callCount == 0)

        #expect(store.setWatermark(.distantPast, forPodcastID: showA, modelContext: context))
        #expect(store.setWatermark(.distantPast, forPodcastID: showA, modelContext: context))
        #expect(probe.callCount == 1)
    }

    private func storedValues(forKey key: String, in container: ModelContainer) throws -> [String] {
        try ModelContext(container)
            .fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == key }
            .map(\.value)
    }

    private func reloadedStore(from container: ModelContainer) -> UpNextAutoAddSettingsStore {
        let store = UpNextAutoAddSettingsStore()
        store.load(modelContext: ModelContext(container))
        return store
    }
}

/// Stands in for the store's save seam, called after the isolated context
/// has been mutated.
private final class UpNextAutoAddSettingsSaveProbe {
    var failsSaves = false
    private(set) var callCount = 0
    private(set) var pendingChangesAtCall: [Bool] = []

    func save(_ context: ModelContext) throws {
        callCount += 1
        pendingChangesAtCall.append(context.hasChanges)
        if failsSaves {
            throw UpNextAutoAddSettingsSaveFailure()
        }
        try context.save()
    }
}

private struct UpNextAutoAddSettingsSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated preference save failure"
    }
}
