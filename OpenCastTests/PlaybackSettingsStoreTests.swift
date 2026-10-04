import Foundation
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
        #expect(store.isAutoSkipPromosAndAdsEnabled)
        #expect(playback.appliedValues == [true])
        #expect(playback.appliedSkipIntervals.count == 1)
        #expect(playback.appliedSkipIntervals.first?.backward == 30)
        #expect(playback.appliedSkipIntervals.first?.forward == 15)
        #expect(playback.appliedAutoSkipValues == [true])
        #expect(playback.appliedRates == [1])
    }

    @Test("Playback speed persists and restores through the shared settings path")
    func playbackSpeedPersistsAndRestores() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(modelContext: context, playback: playback)
        #expect(store.setPlaybackRate(1.5, modelContext: context, playback: playback))

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        PlaybackSettingsStore().load(modelContext: context, playback: reloadedPlayback)

        #expect(playback.appliedRates == [1, 1.5])
        #expect(reloadedPlayback.appliedRates == [1.5])
    }

    @Test("A playback-speed save failure rolls playback back and stays visible")
    func playbackSpeedFailureRollsBackAndSurfacesError() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore { _, _ in
            throw PlaybackSettingsSaveFailure()
        }
        store.load(modelContext: context, playback: playback)

        let didPersist = store.setPlaybackRate(
            1.5,
            modelContext: context,
            playback: playback
        )

        #expect(!didPersist)
        #expect(playback.rate == 1)
        #expect(playback.appliedRates == [1, 1.5, 1])
        #expect(store.lastErrorMessage?.contains("Unable to update playback speed") == true)
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

    @Test("Auto-skip promos and ads defaults on, persists, and applies to playback")
    func autoSkipPromosAndAdsPersistsAndApplies() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()

        store.load(modelContext: context, playback: playback)
        store.setAutoSkipPromosAndAdsEnabled(false, modelContext: context, playback: playback)

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: context, playback: reloadedPlayback)

        #expect(store.isAutoSkipPromosAndAdsEnabled == false)
        #expect(playback.appliedAutoSkipValues == [true, false])
        #expect(reloadedStore.isAutoSkipPromosAndAdsEnabled == false)
        #expect(reloadedPlayback.appliedAutoSkipValues == [false])
    }

    @Test("Tap to Play defaults on")
    func tapToPlayDefaultsOn() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = PlaybackSettingsStore()

        store.load(modelContext: ModelContext(container), playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.isTapToPlayEnabled)
    }

    @Test("Tap to Play off persists and a fresh store reloads it")
    func tapToPlayOffPersistsAndReloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PlaybackSettingsStore()
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.setTapToPlayEnabled(false, modelContext: context))

        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: ModelContext(container), playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.isTapToPlayEnabled == false)
        #expect(store.lastErrorMessage == nil)
        #expect(reloadedStore.isTapToPlayEnabled == false)
    }

    @Test(
        "A Tap to Play save failure restores the shared context without discarding other edits",
        arguments: [nil, "true", "false"] as [String?]
    )
    func tapToPlaySaveFailureRollsBackAndSurfacesError(storedValue: String?) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let previousUpdatedAt = Date(timeIntervalSince1970: 1_000)
        if let storedValue {
            context.insert(LocalPreferenceRecord(
                key: PlaybackSettingsStore.tapToPlayPreferenceKey,
                value: storedValue,
                updatedAt: previousUpdatedAt
            ))
            try context.save()
        }
        let unrelatedPreference = LocalPreferenceRecord(key: "unrelated.pending.preference", value: "keep")
        context.insert(unrelatedPreference)
        let store = PlaybackSettingsStore(save: { _ in
            throw PlaybackSettingsSaveFailure()
        })
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())
        let previousValue = store.isTapToPlayEnabled

        let didPersist = store.setTapToPlayEnabled(!previousValue, modelContext: context)

        #expect(!didPersist)
        #expect(store.isTapToPlayEnabled == previousValue)
        #expect(store.lastErrorMessage?.contains("Unable to update episode tap behavior") == true)

        let restoredRecord = try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.tapToPlayPreferenceKey,
            modelContext: context
        )
        #expect(restoredRecord?.value == storedValue)
        #expect(restoredRecord?.updatedAt == (storedValue == nil ? nil : previousUpdatedAt))
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())
        #expect(store.isTapToPlayEnabled == previousValue)

        try context.save()
        let freshContext = ModelContext(container)
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: freshContext, playback: PlaybackVoiceBoostControllerSpy())
        #expect(reloadedStore.isTapToPlayEnabled == previousValue)
        #expect(try LocalPreferenceRecord.preference(
            forKey: unrelatedPreference.key,
            modelContext: freshContext
        )?.value == "keep")
    }
}

private struct PlaybackSettingsSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated preference save failure"
    }
}
