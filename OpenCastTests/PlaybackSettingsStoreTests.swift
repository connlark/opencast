import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Playback settings store")
struct PlaybackSettingsStoreTests {
    @Test("Playback settings default to per-episode Voice Boost on with 30 back and 15 forward")
    func defaultsApplyToPlayback() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(episodeID: "episode-1", podcastID: "podcast-1", modelContext: context, playback: playback)

        #expect(store.voiceBoostMode == .perEpisode)
        #expect(store.isVoiceBoostEnabled == true)
        #expect(store.canChangeCurrentEpisodeVoiceBoost)
        #expect(store.skipBackwardOption == .thirty)
        #expect(store.skipForwardOption == .fifteen)
        #expect(playback.appliedValues == [true])
        #expect(playback.appliedSkipIntervals.count == 1)
        #expect(playback.appliedSkipIntervals.first?.backward == 30)
        #expect(playback.appliedSkipIntervals.first?.forward == 15)
    }

    @Test("Global Voice Boost off persists and overrides the current episode")
    func globalVoiceBoostOffPersistsAndApplies() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(episodeID: "episode-1", podcastID: "podcast-1", modelContext: context, playback: playback)
        store.setVoiceBoostMode(
            .globalOff,
            episodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: playback
        )

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(
            episodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: reloadedPlayback
        )

        #expect(store.voiceBoostMode == .globalOff)
        #expect(store.isVoiceBoostEnabled == false)
        #expect(playback.appliedValues == [true, false])
        #expect(reloadedStore.voiceBoostMode == .globalOff)
        #expect(reloadedStore.isVoiceBoostEnabled == false)
        #expect(reloadedPlayback.appliedValues == [false])
    }

    @Test("Per-episode Voice Boost toggle persists for only that episode")
    func perEpisodeVoiceBoostPersistsForCurrentEpisode() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(episodeID: "episode-1", podcastID: "podcast-1", modelContext: context, playback: playback)
        store.setVoiceBoostEnabled(
            false,
            forEpisodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: playback
        )

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(
            episodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: reloadedPlayback
        )
        reloadedStore.load(
            episodeID: "episode-2",
            podcastID: "podcast-1",
            modelContext: context,
            playback: reloadedPlayback
        )

        #expect(store.voiceBoostMode == .perEpisode)
        #expect(store.isVoiceBoostEnabled == false)
        #expect(store.canChangeCurrentEpisodeVoiceBoost)
        #expect(reloadedPlayback.appliedValues == [false, true])
        #expect(reloadedStore.currentEpisodeID == "episode-2")
        #expect(reloadedStore.isVoiceBoostEnabled == true)
    }

    @Test("Global Voice Boost modes override per-episode values")
    func globalVoiceBoostModesOverrideEpisodePreference() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(episodeID: "episode-1", podcastID: "podcast-1", modelContext: context, playback: playback)
        store.setVoiceBoostEnabled(
            false,
            forEpisodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: playback
        )
        store.setVoiceBoostMode(
            .globalOn,
            episodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: playback
        )
        store.setVoiceBoostMode(
            .globalOff,
            episodeID: "episode-1",
            podcastID: "podcast-1",
            modelContext: context,
            playback: playback
        )

        #expect(store.isVoiceBoostEnabled == false)
        #expect(playback.appliedValues == [true, false, true, false])
    }

    @Test("Skip interval choices persist and apply to playback")
    func skipIntervalChoicesPersistAndApply() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(modelContext: context, playback: playback)
        store.setSkipBackwardOption(.sixty, modelContext: context, playback: playback)
        store.setSkipForwardOption(.ten, modelContext: context, playback: playback)

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: context, playback: reloadedPlayback)

        #expect(store.skipBackwardOption == .sixty)
        #expect(store.skipForwardOption == .ten)
        #expect(playback.appliedSkipIntervals.last?.backward == 60)
        #expect(playback.appliedSkipIntervals.last?.forward == 10)
        #expect(reloadedStore.skipBackwardOption == .sixty)
        #expect(reloadedStore.skipForwardOption == .ten)
        #expect(reloadedPlayback.appliedSkipIntervals.first?.backward == 60)
        #expect(reloadedPlayback.appliedSkipIntervals.first?.forward == 10)
    }
}
