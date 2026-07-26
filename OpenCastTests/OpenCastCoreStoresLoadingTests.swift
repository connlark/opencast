import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Core store loading")
struct OpenCastCoreStoresLoadingTests {
    @Test("Concurrent and repeated callers share one load")
    func concurrentAndRepeatedCallersShareOneLoad() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let cache = CoreStoresLoadingProbeCacheStore(loadDelay: .milliseconds(100))
        let appModel = OpenCastAppModel(localLibraryCacheStore: cache)

        let firstLoad = Task {
            await appModel.ensureCoreStoresLoaded(modelContext: modelContext)
        }
        let concurrentLoad = Task {
            await appModel.ensureCoreStoresLoaded(modelContext: modelContext)
        }

        await firstLoad.value
        await concurrentLoad.value
        await appModel.ensureCoreStoresLoaded(modelContext: modelContext)

        #expect(await cache.recordedLoadCount() == 1)
        #expect(appModel.library.state == .idle)
    }

    @Test("The one-shot hydrates the per-podcast episode list preferences")
    func hydratesPodcastEpisodeListSettings() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let podcastID = "https://example.com/feed.xml"
        try LocalPreferenceRecord.upsert(
            key: "podcastDetail.filter.\(podcastID)",
            value: PodcastEpisodeFilter.unplayed.rawValue,
            modelContext: modelContext
        )
        try LocalPreferenceRecord.upsert(
            key: "podcastDetail.sortOrder.\(podcastID)",
            value: PodcastEpisodeSortOrder.oldestFirst.rawValue,
            modelContext: modelContext
        )
        try modelContext.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )

        #expect(appModel.podcastEpisodeListSettings.filter(forPodcastID: podcastID) == .all)

        await appModel.ensureCoreStoresLoaded(modelContext: modelContext)

        #expect(appModel.podcastEpisodeListSettings.filter(forPodcastID: podcastID) == .unplayed)
        #expect(appModel.podcastEpisodeListSettings.sortOrder(forPodcastID: podcastID) == .oldestFirst)
    }

    /// Skip zones and the auto-detect decision are read the instant an episode
    /// loads, and a CarPlay-only launch has no phone setup pass to load what
    /// they depend on.
    @Test("Playback dependencies hydrate through their own shared one-shot")
    func hydratesPlaybackDependencies() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: AdDetectionSettingsStore.modePreferenceKey,
            value: AdDetectionMode.cloud.rawValue,
            modelContext: modelContext
        )
        try modelContext.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )

        #expect(appModel.adDetectionSettings.mode == nil)

        await appModel.ensurePlaybackDependenciesLoaded(modelContext: modelContext)
        await appModel.ensurePlaybackDependenciesLoaded(modelContext: modelContext)

        #expect(appModel.adDetectionSettings.mode == .cloud)
    }
}
