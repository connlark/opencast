import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast episode list settings store")
struct PodcastEpisodeListSettingsStoreTests {
    @Test("Sort and filter round trip through a fresh store")
    func roundTrip() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PodcastEpisodeListSettingsStore()
        store.load(modelContext: context)
        #expect(store.setSortOrder(.longestFirst, forPodcastID: "podcast", modelContext: context))
        #expect(store.setFilter(.downloaded, forPodcastID: "podcast", modelContext: context))

        let reloadedStore = PodcastEpisodeListSettingsStore()
        reloadedStore.load(modelContext: context)

        #expect(reloadedStore.sortOrder(forPodcastID: "podcast") == .longestFirst)
        #expect(reloadedStore.filter(forPodcastID: "podcast") == .downloaded)
    }

    @Test("Unknown raw values fall back to defaults")
    func unknownRawValues() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(LocalPreferenceRecord(key: "podcastDetail.sortOrder.podcast", value: "future-sort"))
        context.insert(LocalPreferenceRecord(key: "podcastDetail.filter.podcast", value: "future-filter"))
        try context.save()

        let store = PodcastEpisodeListSettingsStore()
        store.load(modelContext: context)

        #expect(store.sortOrder(forPodcastID: "podcast") == .newestFirst)
        #expect(store.filter(forPodcastID: "podcast") == .all)
    }

    @Test("Removing a podcast clears only its persisted preferences")
    func removePreferences() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PodcastEpisodeListSettingsStore()
        store.load(modelContext: context)
        #expect(store.setSortOrder(.shortestFirst, forPodcastID: "podcast-a", modelContext: context))
        #expect(store.setFilter(.played, forPodcastID: "podcast-a", modelContext: context))
        #expect(store.setSortOrder(.oldestFirst, forPodcastID: "podcast-b", modelContext: context))
        #expect(store.setFilter(.unplayed, forPodcastID: "podcast-b", modelContext: context))

        #expect(store.removePreferences(forPodcastID: "podcast-a", modelContext: context))
        let reloadedStore = PodcastEpisodeListSettingsStore()
        reloadedStore.load(modelContext: context)

        #expect(reloadedStore.sortOrder(forPodcastID: "podcast-a") == .newestFirst)
        #expect(reloadedStore.filter(forPodcastID: "podcast-a") == .all)
        #expect(reloadedStore.sortOrder(forPodcastID: "podcast-b") == .oldestFirst)
        #expect(reloadedStore.filter(forPodcastID: "podcast-b") == .unplayed)
    }
}
