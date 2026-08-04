import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast
@testable import OpenCastPlayback

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

    @Test("Playback speed restores before playback-surface restoration")
    func playbackSpeedRestoresBeforePlaybackSurface() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: PlaybackSettingsStore.playbackRatePreferenceKey,
            value: "1.5",
            modelContext: modelContext
        )
        try modelContext.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )
        var rateAtPlaybackSurfaceRestoration: Float?
        appModel.playbackSurfaceRestorationObserver = {
            rateAtPlaybackSurfaceRestoration = $0
        }

        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)

        #expect(appModel.playback.rate == 1.5)
        #expect(rateAtPlaybackSurfaceRestoration == 1.5)
        #expect(appModel.playbackSurfaceRestorationCount == 1)
    }

    @Test("CarPlay rate cycling persists across app-model launches")
    func carPlayRateCyclePersistsAcrossLaunches() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )
        await appModel.ensureCoreStoresLoaded(modelContext: modelContext)

        #expect(appModel.cyclePlaybackRate(modelContext: modelContext))

        let reloadedAppModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )
        await reloadedAppModel.ensureCoreStoresLoaded(modelContext: modelContext)

        #expect(reloadedAppModel.playback.rate == 1.25)
    }

    @Test("MediaPlayer rate changes persist through the app settings authority")
    func mediaPlayerRateChangePersistsAcrossLaunches() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )
        await appModel.ensureCoreStoresLoaded(modelContext: modelContext)

        appModel.playback.handleRemotePlaybackRateChange(1.5)

        #expect(appModel.playback.rate == 1.5)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: modelContext
        )?.value == "1.5")
        try appModel.playback.load(Episode(
            id: EpisodeID(rawValue: "rate-persistence-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/rate.xml"),
            podcastTitle: "Rate Show",
            title: "Rate Episode",
            duration: 120,
            audioURL: URL(string: "https://example.com/rate.mp3")
        ))
        #expect(appModel.playback.rate == 1.5)

        let reloadedAppModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )
        await reloadedAppModel.ensureCoreStoresLoaded(modelContext: modelContext)

        #expect(reloadedAppModel.playback.rate == 1.5)
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

    @Test("Concurrent and repeated playback-surface hydration restores once")
    func playbackSurfaceHydrationRestoresOnce() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let cache = CoreStoresLoadingProbeCacheStore(loadDelay: .milliseconds(100))
        let appModel = OpenCastAppModel(localLibraryCacheStore: cache)

        let siriHydration = Task {
            await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        }
        let carPlayHydration = Task {
            await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        }

        await siriHydration.value
        await carPlayHydration.value
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)

        #expect(appModel.playbackSurfaceRestorationCount == 1)
        #expect(await cache.recordedLoadCount() == 1)
    }

    @Test("Siri-first hydration followed by the phone restoration tail is idempotent")
    func siriFirstThenPhoneHydration() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )

        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        await appModel.ensurePlaybackSurfaceLoaded(modelContext: modelContext)
        appModel.restorePlaybackSurfaceIfNeeded(modelContext: modelContext)

        #expect(appModel.playbackSurfaceRestorationCount == 1)
    }

    @Test("CarPlay-first hydration followed by Siri hydration is idempotent")
    func carPlayFirstThenSiriHydration() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory()
        )

        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)

        #expect(appModel.playbackSurfaceRestorationCount == 1)
    }
}
