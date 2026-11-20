import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Download settings store")
struct DownloadSettingsStoreTests {
    private let showA = "https://example.com/a.xml"
    private let showB = "https://example.com/b.xml"

    @Test("Preference keys stay stable")
    func preferenceKeysStayStable() {
        #expect(DownloadSettingsStore.autoDownloadKeyPrefix == "downloads.autoDownloadNewEpisodes.")
        #expect(DownloadSettingsStore.autoDownloadWatermarkKeyPrefix == "downloads.autoDownloadWatermark.")
        #expect(DownloadSettingsStore.keepLimitKeyPrefix == "downloads.keepLimit.")
        #expect(DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix == "downloads.detectAdsInNewEpisodes.")
        #expect(DownloadSettingsStore.detectAdsPendingKeyPrefix == "downloads.detectAdsPending.")
        #expect(DownloadSettingsStore.defaultKeepLimitPreferenceKey == "downloads.defaultKeepLimit")
        #expect(DownloadSettingsStore.autoDownloadsWiFiOnlyPreferenceKey == "downloads.autoDownloadsWiFiOnly")
        #expect(DownloadSettingsStore.listGroupingPreferenceKey == "downloads.listGrouping")
        #expect(DownloadKeepLimit.allCases.map(\.rawValue) == ["noLimit", "1", "2", "3", "5", "10"])
        #expect(DownloadsListGrouping.allCases.map(\.rawValue) == ["flat", "byShow"])
    }

    @Test("Keep limits title and count themselves")
    func keepLimitTitles() {
        #expect(DownloadKeepLimit.noLimit.maximumCount == nil)
        #expect(DownloadKeepLimit.ten.maximumCount == 10)
        #expect(DownloadKeepLimit.noLimit.title == "No Limit")
        #expect(DownloadKeepLimit.one.title == "1 Episode")
        #expect(DownloadKeepLimit.three.title == "3 Episodes")
        #expect(DownloadKeepLimit.noLimit.shortTitle == "No limit")
        #expect(DownloadKeepLimit.five.shortTitle == "Keep 5")
    }

    @Test("Defaults: every show manual and unlimited, Wi-Fi only on, flat list")
    func defaultsWithoutStoredRows() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = DownloadSettingsStore()

        store.load(modelContext: ModelContext(container))

        #expect(store.autoDownloadPodcastIDs.isEmpty)
        #expect(!store.autoDownloadsNewEpisodes(forPodcastID: showA))
        #expect(store.autoDownloadWatermark(forPodcastID: showA) == nil)
        #expect(store.keepLimitOverride(forPodcastID: showA) == nil)
        #expect(store.resolvedKeepLimit(forPodcastID: showA) == .noLimit)
        #expect(store.defaultKeepLimit == .noLimit)
        #expect(store.autoDownloadsRequireWiFi)
        #expect(store.listGrouping == .flat)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Every setting round-trips through a fresh store, per show and with the exact watermark")
    func settingsRoundTrip() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        let watermark = Date(timeIntervalSinceReferenceDate: 783_456_789.123_456_7)

        #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: showA, watermark: watermark, modelContext: context))
        #expect(store.setKeepLimitOverride(.two, forPodcastID: showB, modelContext: context))
        #expect(store.setDefaultKeepLimit(.five, modelContext: context))
        #expect(store.setAutoDownloadsRequireWiFi(false, modelContext: context))
        #expect(store.setListGrouping(.byShow, modelContext: context))

        let reloaded = reloadedStore(from: container)
        #expect(reloaded.autoDownloadPodcastIDs == [showA])
        #expect(reloaded.autoDownloadsNewEpisodes(forPodcastID: showA))
        #expect(!reloaded.autoDownloadsNewEpisodes(forPodcastID: showB))
        #expect(reloaded.autoDownloadWatermark(forPodcastID: showA) == watermark)
        #expect(reloaded.keepLimitOverride(forPodcastID: showA) == nil)
        #expect(reloaded.keepLimitOverride(forPodcastID: showB) == .two)
        #expect(reloaded.resolvedKeepLimit(forPodcastID: showA) == .five)
        #expect(reloaded.resolvedKeepLimit(forPodcastID: showB) == .two)
        #expect(reloaded.defaultKeepLimit == .five)
        #expect(!reloaded.autoDownloadsRequireWiFi)
        #expect(reloaded.listGrouping == .byShow)

        let advanced = watermark.addingTimeInterval(86_400.5)
        #expect(store.setAutoDownloadWatermark(advanced, forPodcastID: showA, modelContext: context))
        #expect(reloadedStore(from: container).autoDownloadWatermark(forPodcastID: showA) == advanced)
        #expect(try storedValues(forKey: DownloadSettingsStore.autoDownloadWatermarkKeyPrefix + showA, in: container).count == 1)
    }

    @Test("Default deletes the show's limit row and the show follows the global default again")
    func nilOverrideDeletesRow() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        let key = DownloadSettingsStore.keepLimitKeyPrefix + showA

        #expect(store.setKeepLimitOverride(.one, forPodcastID: showA, modelContext: context))
        #expect(store.setDefaultKeepLimit(.three, modelContext: context))
        #expect(store.resolvedKeepLimit(forPodcastID: showA) == .one)
        #expect(try storedValues(forKey: key, in: container) == ["1"])

        #expect(store.setKeepLimitOverride(nil, forPodcastID: showA, modelContext: context))

        #expect(store.keepLimitOverride(forPodcastID: showA) == nil)
        #expect(store.resolvedKeepLimit(forPodcastID: showA) == .three)
        #expect(try storedValues(forKey: key, in: container).isEmpty)
        #expect(reloadedStore(from: container).resolvedKeepLimit(forPodcastID: showA) == .three)
    }

    @Test("Turning a show off deletes its flag and watermark; a watermark needs the show on")
    func disablingDeletesWatermark() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        let flagKey = DownloadSettingsStore.autoDownloadKeyPrefix + showA
        let watermarkKey = DownloadSettingsStore.autoDownloadWatermarkKeyPrefix + showA

        #expect(!store.setAutoDownloadWatermark(.now, forPodcastID: showA, modelContext: context))
        #expect(try storedValues(forKey: watermarkKey, in: container).isEmpty)

        #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: showA, watermark: .distantPast, modelContext: context))
        #expect(try storedValues(forKey: flagKey, in: container) == ["true"])
        #expect(try storedValues(forKey: watermarkKey, in: container).count == 1)
        #expect(store.autoDownloadWatermark(forPodcastID: showA) == .distantPast)

        #expect(store.setAutoDownloadsNewEpisodes(false, forPodcastID: showA, modelContext: context))

        #expect(!store.autoDownloadsNewEpisodes(forPodcastID: showA))
        #expect(store.autoDownloadWatermark(forPodcastID: showA) == nil)
        #expect(try storedValues(forKey: flagKey, in: container).isEmpty)
        #expect(try storedValues(forKey: watermarkKey, in: container).isEmpty)
        #expect(reloadedStore(from: container).autoDownloadPodcastIDs.isEmpty)
    }

    @Test("Unknown stored values load as defaults")
    func unknownStoredValuesFallBack() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for (key, value) in [
            (DownloadSettingsStore.autoDownloadKeyPrefix + showA, "yes"),
            (DownloadSettingsStore.autoDownloadWatermarkKeyPrefix + showA, "yesterday"),
            (DownloadSettingsStore.keepLimitKeyPrefix + showA, "4"),
            (DownloadSettingsStore.defaultKeepLimitPreferenceKey, "7"),
            (DownloadSettingsStore.autoDownloadsWiFiOnlyPreferenceKey, "maybe"),
            (DownloadSettingsStore.listGroupingPreferenceKey, "byColor"),
            (DownloadSettingsStore.keepLimitKeyPrefix, "2"),
        ] {
            context.insert(LocalPreferenceRecord(key: key, value: value))
        }
        try context.save()

        let store = reloadedStore(from: container)

        #expect(store.autoDownloadPodcastIDs.isEmpty)
        #expect(store.autoDownloadWatermark(forPodcastID: showA) == nil)
        #expect(store.keepLimitOverride(forPodcastID: showA) == nil)
        #expect(store.keepLimitOverride(forPodcastID: "") == nil)
        #expect(store.defaultKeepLimit == .noLimit)
        #expect(store.autoDownloadsRequireWiFi)
        #expect(store.listGrouping == .flat)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("The newest duplicate row wins")
    func newestDuplicateWins() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let key = DownloadSettingsStore.keepLimitKeyPrefix + showA
        context.insert(LocalPreferenceRecord(key: key, value: "1", updatedAt: Date(timeIntervalSinceReferenceDate: 100)))
        context.insert(LocalPreferenceRecord(key: key, value: "10", updatedAt: Date(timeIntervalSinceReferenceDate: 200)))
        try context.save()

        #expect(reloadedStore(from: container).keepLimitOverride(forPodcastID: showA) == .ten)
    }

    @Test("Removing a show's preferences clears only that show's four rows and its markers")
    func removePreferencesIsScoped() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        for show in [showA, showB] {
            #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: show, watermark: .distantPast, modelContext: context))
            #expect(store.setKeepLimitOverride(.three, forPodcastID: show, modelContext: context))
            #expect(store.setDetectsAdsInNewEpisodes(true, forPodcastID: show, modelContext: context))
        }
        #expect(store.addDetectAdsPendingMarkers(["a-1": showA, "a-2": showA, "b-1": showB], modelContext: context))
        #expect(store.setDefaultKeepLimit(.ten, modelContext: context))

        #expect(store.removePreferences(forPodcastID: showA, modelContext: context))

        for reloaded in [store, reloadedStore(from: container)] {
            #expect(reloaded.autoDownloadPodcastIDs == [showB])
            #expect(reloaded.autoDownloadWatermark(forPodcastID: showA) == nil)
            #expect(reloaded.autoDownloadWatermark(forPodcastID: showB) == .distantPast)
            #expect(reloaded.keepLimitOverride(forPodcastID: showA) == nil)
            #expect(reloaded.keepLimitOverride(forPodcastID: showB) == .three)
            #expect(reloaded.detectAdsPodcastIDs == [showB])
            #expect(reloaded.detectAdsPendingPodcastIDsByEpisodeID == ["b-1": showB])
            #expect(reloaded.defaultKeepLimit == .ten)
        }
        for prefix in [
            DownloadSettingsStore.autoDownloadKeyPrefix,
            DownloadSettingsStore.autoDownloadWatermarkKeyPrefix,
            DownloadSettingsStore.keepLimitKeyPrefix,
            DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix,
        ] {
            #expect(try storedValues(forKey: prefix + showA, in: container).isEmpty)
            #expect(try storedValues(forKey: prefix + showB, in: container).count == 1)
        }
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "a-1", in: container).isEmpty)
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "a-2", in: container).isEmpty)
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "b-1", in: container) == [showB])
    }

    @Test("Detect Ads in New Episodes needs Download New Episodes, round-trips, and off deletes the show's markers")
    func detectAdsFlagSetAndUnset() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        let flagKey = DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix + showA

        #expect(!store.setDetectsAdsInNewEpisodes(true, forPodcastID: showA, modelContext: context))
        #expect(!store.detectsAdsInNewEpisodes(forPodcastID: showA))
        #expect(try storedValues(forKey: flagKey, in: container).isEmpty)

        #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: showA, watermark: .distantPast, modelContext: context))
        #expect(store.setDetectsAdsInNewEpisodes(true, forPodcastID: showA, modelContext: context))
        #expect(store.detectsAdsInNewEpisodes(forPodcastID: showA))
        #expect(!store.detectsAdsInNewEpisodes(forPodcastID: showB))
        #expect(try storedValues(forKey: flagKey, in: container) == ["true"])
        #expect(reloadedStore(from: container).detectAdsPodcastIDs == [showA])
        #expect(store.addDetectAdsPendingMarkers(["a-1": showA], modelContext: context))

        #expect(store.setDetectsAdsInNewEpisodes(false, forPodcastID: showA, modelContext: context))

        #expect(!store.detectsAdsInNewEpisodes(forPodcastID: showA))
        #expect(store.autoDownloadsNewEpisodes(forPodcastID: showA))
        #expect(store.detectAdsPendingPodcastID(forEpisodeID: "a-1") == nil)
        #expect(try storedValues(forKey: flagKey, in: container).isEmpty)
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "a-1", in: container).isEmpty)
        let reloaded = reloadedStore(from: container)
        #expect(reloaded.detectAdsPodcastIDs.isEmpty)
        #expect(reloaded.detectAdsPendingPodcastIDsByEpisodeID.isEmpty)
        #expect(reloaded.autoDownloadPodcastIDs == [showA])
    }

    @Test("Download New Episodes off turns Detect Ads in New Episodes off and deletes only that show's markers")
    func autoDownloadOffClearsDetectAds() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        for show in [showA, showB] {
            #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: show, watermark: .distantPast, modelContext: context))
            #expect(store.setDetectsAdsInNewEpisodes(true, forPodcastID: show, modelContext: context))
        }
        #expect(store.addDetectAdsPendingMarkers(["a-1": showA, "b-1": showB], modelContext: context))

        #expect(store.setAutoDownloadsNewEpisodes(false, forPodcastID: showA, modelContext: context))

        for reloaded in [store, reloadedStore(from: container)] {
            #expect(reloaded.autoDownloadPodcastIDs == [showB])
            #expect(reloaded.detectAdsPodcastIDs == [showB])
            #expect(reloaded.detectAdsPendingPodcastIDsByEpisodeID == ["b-1": showB])
        }
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix + showA, in: container).isEmpty)
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "a-1", in: container).isEmpty)
    }

    @Test("Markers survive a reload, a show without the flag gets none, and removal deletes only the named ones")
    func pendingMarkersRoundTrip() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadSettingsStore()
        store.load(modelContext: context)
        #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: showA, watermark: .distantPast, modelContext: context))
        #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: showB, watermark: .distantPast, modelContext: context))
        #expect(store.setDetectsAdsInNewEpisodes(true, forPodcastID: showA, modelContext: context))

        #expect(store.addDetectAdsPendingMarkers(["a-1": showA, "a-2": showA, "b-1": showB], modelContext: context))

        #expect(store.detectAdsPendingPodcastIDsByEpisodeID == ["a-1": showA, "a-2": showA])
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "b-1", in: container).isEmpty)
        let reloaded = reloadedStore(from: container)
        #expect(reloaded.detectAdsPendingPodcastIDsByEpisodeID == ["a-1": showA, "a-2": showA])
        #expect(reloaded.detectAdsPendingPodcastID(forEpisodeID: "a-2") == showA)

        #expect(store.removeDetectAdsPendingMarkers(forEpisodeIDs: ["a-1", "unknown"], modelContext: context))

        #expect(store.detectAdsPendingPodcastIDsByEpisodeID == ["a-2": showA])
        #expect(reloadedStore(from: container).detectAdsPendingPodcastIDsByEpisodeID == ["a-2": showA])
        #expect(try storedValues(forKey: DownloadSettingsStore.detectAdsPendingKeyPrefix + "a-1", in: container).isEmpty)
    }

    @Test("No new prefix extends another key, and a key that only starts like one is not misread")
    func detectAdsKeysDoNotCollide() throws {
        let prefixes = [
            DownloadSettingsStore.autoDownloadKeyPrefix,
            DownloadSettingsStore.autoDownloadWatermarkKeyPrefix,
            DownloadSettingsStore.keepLimitKeyPrefix,
            DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix,
            DownloadSettingsStore.detectAdsPendingKeyPrefix,
        ]
        let keys = prefixes + [
            DownloadSettingsStore.defaultKeepLimitPreferenceKey,
            DownloadSettingsStore.autoDownloadsWiFiOnlyPreferenceKey,
            DownloadSettingsStore.listGroupingPreferenceKey,
            DownloadStore.autoDeletePlayedEpisodesPreferenceKey,
        ]
        for prefix in prefixes {
            for key in keys where key != prefix {
                #expect(!key.hasPrefix(prefix), "\(key) would load as a \(prefix) row")
            }
        }

        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for (key, value) in [
            (DownloadSettingsStore.autoDownloadKeyPrefix + showA, "true"),
            (DownloadSettingsStore.detectAdsInNewEpisodesKeyPrefix + showB, "true"),
            (DownloadSettingsStore.detectAdsPendingKeyPrefix + "b-1", showB),
            ("downloads.detectAdsInNewEpisodesFor." + showA, "true"),
            ("downloads.detectAdsPendingEpisode." + showA, showA),
            (DownloadSettingsStore.detectAdsPendingKeyPrefix, showA),
            (DownloadSettingsStore.detectAdsPendingKeyPrefix + "empty", ""),
        ] {
            context.insert(LocalPreferenceRecord(key: key, value: value))
        }
        try context.save()

        let store = reloadedStore(from: container)

        #expect(store.autoDownloadPodcastIDs == [showA])
        #expect(store.detectAdsPodcastIDs == [showB])
        #expect(store.detectAdsPendingPodcastIDsByEpisodeID == ["b-1": showB])
        #expect(store.autoDownloadWatermark(forPodcastID: showB) == nil)
        #expect(store.keepLimitOverride(forPodcastID: showB) == nil)
    }

    @Test("A failed save keeps the previous value in memory and storage, with a message")
    func failedSaveKeepsPreviousValue() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = DownloadSettingsSaveProbe()
        let store = DownloadSettingsStore(save: probe.save)
        store.load(modelContext: context)
        #expect(store.setKeepLimitOverride(.two, forPodcastID: showA, modelContext: context))
        probe.failsSaves = true

        #expect(!store.setKeepLimitOverride(.five, forPodcastID: showA, modelContext: context))
        #expect(store.keepLimitOverride(forPodcastID: showA) == .two)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Keep Downloaded") == true)
        #expect(!store.setAutoDownloadsNewEpisodes(true, forPodcastID: showA, watermark: .now, modelContext: context))
        #expect(!store.autoDownloadsNewEpisodes(forPodcastID: showA))
        #expect(!store.setAutoDownloadsRequireWiFi(false, modelContext: context))
        #expect(store.autoDownloadsRequireWiFi)
        #expect(!store.setListGrouping(.byShow, modelContext: context))
        #expect(store.listGrouping == .flat)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Group by Show") == true)
        #expect(probe.pendingChangesAtCall.allSatisfy { $0 })

        let reloaded = reloadedStore(from: container)
        #expect(reloaded.keepLimitOverride(forPodcastID: showA) == .two)
        #expect(reloaded.autoDownloadPodcastIDs.isEmpty)
        #expect(reloaded.autoDownloadsRequireWiFi)

        probe.failsSaves = false
        #expect(store.setListGrouping(.byShow, modelContext: context))
        #expect(store.lastErrorMessage == nil)
    }

    @Test("A watermark save leaves an unread error message alone")
    func watermarkSaveKeepsErrorMessage() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = DownloadSettingsSaveProbe()
        let store = DownloadSettingsStore(save: probe.save)
        store.load(modelContext: context)
        #expect(store.setAutoDownloadsNewEpisodes(true, forPodcastID: showA, watermark: .distantPast, modelContext: context))
        probe.failsSaves = true
        #expect(!store.setDefaultKeepLimit(.one, modelContext: context))
        probe.failsSaves = false

        #expect(store.setAutoDownloadWatermark(.now, forPodcastID: showA, modelContext: context))

        #expect(store.lastErrorMessage?.hasPrefix("Unable to update Keep Downloaded") == true)
    }

    @Test("Unchanged values skip the save")
    func noOpSettersSkipSave() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let probe = DownloadSettingsSaveProbe()
        let store = DownloadSettingsStore(save: probe.save)
        store.load(modelContext: context)

        #expect(store.setKeepLimitOverride(nil, forPodcastID: showA, modelContext: context))
        #expect(store.setDefaultKeepLimit(.noLimit, modelContext: context))
        #expect(store.setAutoDownloadsRequireWiFi(true, modelContext: context))
        #expect(store.setListGrouping(.flat, modelContext: context))
        #expect(store.setAutoDownloadsNewEpisodes(false, forPodcastID: showA, modelContext: context))
        #expect(store.setDetectsAdsInNewEpisodes(false, forPodcastID: showA, modelContext: context))
        #expect(store.addDetectAdsPendingMarkers(["a-1": showA], modelContext: context))
        #expect(store.removeDetectAdsPendingMarkers(forEpisodeIDs: ["a-1"], modelContext: context))

        #expect(probe.callCount == 0)
    }

    private func storedValues(forKey key: String, in container: ModelContainer) throws -> [String] {
        try ModelContext(container)
            .fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == key }
            .map(\.value)
    }

    private func reloadedStore(from container: ModelContainer) -> DownloadSettingsStore {
        let store = DownloadSettingsStore()
        store.load(modelContext: ModelContext(container))
        return store
    }
}

private final class DownloadSettingsSaveProbe {
    var failsSaves = false
    private(set) var callCount = 0
    private(set) var pendingChangesAtCall: [Bool] = []

    func save(_ context: ModelContext) throws {
        callCount += 1
        pendingChangesAtCall.append(context.hasChanges)
        if failsSaves {
            throw DownloadSettingsSaveFailure()
        }
        try context.save()
    }
}

private struct DownloadSettingsSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated preference save failure"
    }
}
