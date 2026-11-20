import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Playback settings store")
struct PlaybackSettingsStoreTests {
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

    @Test(
        "A global playback-speed save failure restores the stored speed without discarding other edits",
        arguments: [nil, "1.25"] as [String?]
    )
    func globalPlaybackSpeedFailureRestoresTheStoredSpeed(storedValue: String?) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let previousUpdatedAt = Date(timeIntervalSince1970: 1_000)
        if let storedValue {
            context.insert(LocalPreferenceRecord(
                key: PlaybackSettingsStore.playbackRatePreferenceKey,
                value: storedValue,
                updatedAt: previousUpdatedAt
            ))
            try context.save()
        }
        let unrelatedPreference = LocalPreferenceRecord(key: "unrelated.pending.preference", value: "keep")
        context.insert(unrelatedPreference)
        var failsSaves = true
        let store = PlaybackSettingsStore(save: { context in
            if failsSaves {
                throw PlaybackSettingsSaveFailure()
            }
            try context.save()
        })
        let playback = PlaybackVoiceBoostControllerSpy()
        store.load(modelContext: context, playback: playback)
        let previousRate = store.globalPlaybackRate

        #expect(!store.setPlaybackRate(2, modelContext: context, playback: playback))

        #expect(store.globalPlaybackRate == previousRate)
        #expect(playback.rate == previousRate)
        let restoredRecord = try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: context
        )
        #expect(restoredRecord?.value == storedValue)
        #expect(restoredRecord?.updatedAt == (storedValue == nil ? nil : previousUpdatedAt))
        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        PlaybackSettingsStore().load(modelContext: context, playback: reloadedPlayback)
        #expect(reloadedPlayback.rate == previousRate)

        failsSaves = false
        #expect(store.setTapToPlayEnabled(false, modelContext: context))

        let freshContext = ModelContext(container)
        let freshPlayback = PlaybackVoiceBoostControllerSpy()
        PlaybackSettingsStore().load(modelContext: freshContext, playback: freshPlayback)
        #expect(freshPlayback.rate == previousRate)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: freshContext
        )?.value == storedValue)
        #expect(try LocalPreferenceRecord.preference(
            forKey: unrelatedPreference.key,
            modelContext: freshContext
        )?.value == "keep")
    }

    @Test("A show's speed applies on load and leaves the global speed and its preference alone")
    func loadAppliesTheShowSpeedWithoutTouchingTheGlobalSpeed() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        store.load(modelContext: context, playback: playback)
        #expect(store.setPlaybackRate(1.25, modelContext: context, playback: playback))
        #expect(store.globalPlaybackRate == 1.25)

        store.load(
            episodeID: "episode-1",
            podcastID: "podcast-1",
            rateOverride: 1.75,
            modelContext: context,
            playback: playback
        )

        #expect(playback.rate == 1.75)
        #expect(store.globalPlaybackRate == 1.25)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: context
        )?.value == "1.25")
    }

    @Test("A show-scope speed change persists through its closure and never writes the global preference")
    func showScopeSpeedChangePersistsThroughTheClosure() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        store.load(episodeID: "episode-1", podcastID: "podcast-1", rateOverride: 1.5, modelContext: context, playback: playback)
        var persistedRates: [Float] = []

        let didPersist = store.setPlaybackRate(
            5,
            modelContext: context,
            playback: playback,
            persist: { rate, _ in persistedRates.append(rate) }
        )

        #expect(didPersist)
        #expect(persistedRates == [3])
        #expect(playback.rate == 3)
        #expect(store.globalPlaybackRate == 1)
        #expect(store.lastErrorMessage == nil)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: context
        ) == nil)
    }

    @Test("A show-scope save failure that carries its own message surfaces it unchanged")
    func showScopeSaveFailureMessageSurfacesUnchanged() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        store.load(episodeID: "episode-1", podcastID: "podcast-1", rateOverride: 1.5, modelContext: context, playback: playback)

        let didPersist = store.setPlaybackRate(
            2,
            modelContext: context,
            playback: playback,
            persist: { _, _ in
                throw PodcastPlaybackRateSaveError(message: "Unable to update this show's speed: Disk full")
            }
        )

        #expect(!didPersist)
        #expect(playback.rate == 1.5)
        #expect(store.lastErrorMessage == "Unable to update this show's speed: Disk full")
    }

    @Test("A show-scope speed already playing still persists through its closure")
    func showScopeSpeedAlreadyPlayingStillPersists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        store.load(episodeID: "episode-1", podcastID: "podcast-1", rateOverride: 1.5, modelContext: context, playback: playback)
        var persistedRates: [Float] = []

        let didPersist = store.setPlaybackRate(
            1.5,
            modelContext: context,
            playback: playback,
            persist: { rate, _ in persistedRates.append(rate) }
        )

        #expect(didPersist)
        #expect(persistedRates == [1.5])
        #expect(playback.rate == 1.5)
        #expect(playback.appliedRates == [1.5])
        #expect(store.globalPlaybackRate == 1)
    }

    @Test("A global speed already playing is saved when the stored global speed differs")
    func globalSpeedAlreadyPlayingIsSavedWhenTheStoredSpeedDiffers() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        store.load(episodeID: "episode-1", podcastID: "podcast-1", rateOverride: 1.5, modelContext: context, playback: playback)

        #expect(store.setPlaybackRate(1.5, modelContext: context, playback: playback))

        #expect(playback.appliedRates == [1.5])
        #expect(store.globalPlaybackRate == 1.5)
        #expect(store.lastErrorMessage == nil)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: ModelContext(container)
        )?.value == "1.5")
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

    @Test("Skip Sound defaults to None, which gives the controller no cue and looks up no file")
    func skipSoundDefaultsToNone() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let lookups = SkipSoundLookupRecorder()
        let store = PlaybackSettingsStore(skipSoundURL: lookups.url(for:))

        store.load(modelContext: context, playback: playback)
        store.setAutoSkipPromosAndAdsEnabled(false, modelContext: context, playback: playback)
        store.setAutoSkipPromosAndAdsEnabled(true, modelContext: context, playback: playback)

        #expect(store.autoSkipSound == nil)
        #expect(playback.appliedAutoSkipCues == [nil, nil, nil])
        #expect(playback.previewedAutoSkipCues.isEmpty)
        #expect(lookups.sounds.isEmpty)
    }

    @Test("A chosen skip sound persists, reaches the controller as the catalog's file and plays once")
    func skipSoundChoicePersistsAndReachesTheController() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        let rewind = try #require(SkipSoundCatalog.sound(id: "rewind"))
        let rewindURL = try #require(SkipSoundCatalog.url(for: rewind, in: .main))
        store.load(modelContext: context, playback: playback)

        #expect(store.setAutoSkipSound(rewind, modelContext: context, playback: playback))

        #expect(store.autoSkipSound == rewind)
        #expect(store.lastErrorMessage == nil)
        #expect(playback.appliedAutoSkipCues == [nil, rewindURL])
        #expect(playback.previewedAutoSkipCues == [rewindURL])
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.autoSkipSoundPreferenceKey,
            modelContext: context
        )?.value == "rewind")

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: ModelContext(container), playback: reloadedPlayback)

        #expect(reloadedStore.autoSkipSound == rewind)
        #expect(reloadedPlayback.appliedAutoSkipCues == [rewindURL])
        #expect(reloadedPlayback.previewedAutoSkipCues.isEmpty)
    }

    @Test("Choosing None clears the cue, plays nothing and persists")
    func choosingNoneClearsTheCueAndPlaysNothing() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        let rewind = try #require(SkipSoundCatalog.sound(id: "rewind"))
        let rewindURL = try #require(SkipSoundCatalog.url(for: rewind, in: .main))
        store.load(modelContext: context, playback: playback)
        store.setAutoSkipSound(rewind, modelContext: context, playback: playback)

        #expect(store.setAutoSkipSound(nil, modelContext: context, playback: playback))

        #expect(store.autoSkipSound == nil)
        #expect(playback.appliedAutoSkipCues == [nil, rewindURL, nil])
        #expect(playback.previewedAutoSkipCues == [rewindURL])
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: ModelContext(container), playback: PlaybackVoiceBoostControllerSpy())
        #expect(reloadedStore.autoSkipSound == nil)
    }

    @Test("Choosing the sound already chosen plays it again without writing it again")
    func choosingTheCurrentSoundPlaysItAgain() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        let cassette = try #require(SkipSoundCatalog.sound(id: "cassette"))
        let cassetteURL = try #require(SkipSoundCatalog.url(for: cassette, in: .main))
        store.load(modelContext: context, playback: playback)
        store.setAutoSkipSound(cassette, modelContext: context, playback: playback)
        let firstWrite = try #require(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.autoSkipSoundPreferenceKey,
            modelContext: context
        )?.updatedAt)

        #expect(store.setAutoSkipSound(cassette, modelContext: context, playback: playback))

        #expect(playback.appliedAutoSkipCues == [nil, cassetteURL])
        #expect(playback.previewedAutoSkipCues == [cassetteURL, cassetteURL])
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.autoSkipSoundPreferenceKey,
            modelContext: context
        )?.updatedAt == firstWrite)
    }

    @Test("Auto-Skip off gives the controller no cue and keeps the choice, which comes back when it goes on")
    func autoSkipOffWithholdsTheCueAndKeepsTheChoice() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore()
        let rewind = try #require(SkipSoundCatalog.sound(id: "rewind"))
        let rewindURL = try #require(SkipSoundCatalog.url(for: rewind, in: .main))
        store.load(modelContext: context, playback: playback)
        store.setAutoSkipSound(rewind, modelContext: context, playback: playback)

        store.setAutoSkipPromosAndAdsEnabled(false, modelContext: context, playback: playback)

        #expect(playback.autoSkipCalls.suffix(2) == [.cue(nil), .enabled(false)])
        #expect(store.autoSkipSound == rewind)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.autoSkipSoundPreferenceKey,
            modelContext: context
        )?.value == "rewind")

        let offPlayback = PlaybackVoiceBoostControllerSpy()
        let offLookups = SkipSoundLookupRecorder()
        let offStore = PlaybackSettingsStore(skipSoundURL: offLookups.url(for:))
        offStore.load(modelContext: ModelContext(container), playback: offPlayback)
        #expect(offStore.autoSkipSound == rewind)
        #expect(offPlayback.appliedAutoSkipCues == [nil])
        #expect(offLookups.sounds.isEmpty)

        store.setAutoSkipPromosAndAdsEnabled(true, modelContext: context, playback: playback)

        // The cue arrives before the switch, so a skip the switch itself
        // triggers inside a zone carries the sound.
        #expect(playback.autoSkipCalls.suffix(2) == [.cue(rewindURL), .enabled(true)])
        #expect(store.autoSkipSound == rewind)
        #expect(playback.previewedAutoSkipCues == [rewindURL])
    }

    @Test(
        "A skip sound save failure restores the choice, the cue and the stored value and plays nothing",
        arguments: [nil, "cassette"] as [String?]
    )
    func skipSoundSaveFailureRollsBack(storedValue: String?) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let previousUpdatedAt = Date(timeIntervalSince1970: 1_000)
        if let storedValue {
            context.insert(LocalPreferenceRecord(
                key: PlaybackSettingsStore.autoSkipSoundPreferenceKey,
                value: storedValue,
                updatedAt: previousUpdatedAt
            ))
            try context.save()
        }
        let unrelatedPreference = LocalPreferenceRecord(key: "unrelated.pending.preference", value: "keep")
        context.insert(unrelatedPreference)
        let playback = PlaybackVoiceBoostControllerSpy()
        let store = PlaybackSettingsStore(save: { _ in
            throw PlaybackSettingsSaveFailure()
        })
        store.load(modelContext: context, playback: playback)
        let previousSound = store.autoSkipSound
        let previousURL = previousSound.flatMap { SkipSoundCatalog.url(for: $0, in: .main) }
        #expect(previousSound?.id == storedValue)
        let rewind = try #require(SkipSoundCatalog.sound(id: "rewind"))
        let rewindURL = try #require(SkipSoundCatalog.url(for: rewind, in: .main))

        let didPersist = store.setAutoSkipSound(rewind, modelContext: context, playback: playback)

        #expect(!didPersist)
        #expect(store.autoSkipSound == previousSound)
        #expect(playback.appliedAutoSkipCues == [previousURL, rewindURL, previousURL])
        #expect(playback.previewedAutoSkipCues.isEmpty)
        #expect(store.lastErrorMessage?.contains("Unable to update the skip sound") == true)

        let restoredRecord = try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.autoSkipSoundPreferenceKey,
            modelContext: context
        )
        #expect(restoredRecord?.value == storedValue)
        #expect(restoredRecord?.updatedAt == (storedValue == nil ? nil : previousUpdatedAt))

        try context.save()
        let freshContext = ModelContext(container)
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: freshContext, playback: PlaybackVoiceBoostControllerSpy())
        #expect(reloadedStore.autoSkipSound == previousSound)
        #expect(try LocalPreferenceRecord.preference(
            forKey: unrelatedPreference.key,
            modelContext: freshContext
        )?.value == "keep")
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

    @Test("Requeue Interrupted Episode on persists and a fresh store reloads it")
    func requeueInterruptedEpisodeOnPersistsAndReloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PlaybackSettingsStore()
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.setRequeueInterruptedEpisodeEnabled(true, modelContext: context))

        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: ModelContext(container), playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.isRequeueInterruptedEpisodeEnabled)
        #expect(store.lastErrorMessage == nil)
        #expect(reloadedStore.isRequeueInterruptedEpisodeEnabled)
    }

    @Test("A sleep timer preset slot persists and a fresh store reloads it")
    func sleepTimerPresetPersistsAndReloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PlaybackSettingsStore()
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.setSleepTimerPreset(.twenty, at: 0, modelContext: context))
        #expect(store.setSleepTimerPreset(.oneHundredTwenty, at: 5, modelContext: context))

        let reloadedStore = PlaybackSettingsStore()
        let freshContext = ModelContext(container)
        reloadedStore.load(modelContext: freshContext, playback: PlaybackVoiceBoostControllerSpy())

        let expected: [SleepTimerPresetDuration] = [.twenty, .ten, .fifteen, .thirty, .fortyFive, .oneHundredTwenty]
        #expect(store.sleepTimerPresets == expected)
        #expect(store.lastErrorMessage == nil)
        #expect(reloadedStore.sleepTimerPresets == expected)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.sleepTimerPresetsPreferenceKey,
            modelContext: freshContext
        )?.value == "[20,10,15,30,45,120]")
    }

    @Test("A sleep timer preset already held by another slot or outside the six slots is refused")
    func sleepTimerPresetRefusesDuplicatesAndBadSlots() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PlaybackSettingsStore()
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())

        #expect(!store.setSleepTimerPreset(.ten, at: 0, modelContext: context))
        #expect(!store.setSleepTimerPreset(.twenty, at: 6, modelContext: context))
        #expect(!store.setSleepTimerPreset(.twenty, at: -1, modelContext: context))
        #expect(store.setSleepTimerPreset(.five, at: 0, modelContext: context))

        #expect(store.sleepTimerPresets == SleepTimerPresetDuration.defaults)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.sleepTimerPresetsPreferenceKey,
            modelContext: context
        ) == nil)
    }

    @Test(
        "Unusable stored sleep timer presets load as defaults without rewriting storage",
        arguments: [
            "garbage",
            "[5,10,15]",
            "[5,10,15,30,45,61]",
            "[5,5,15,30,45,60]",
            "[5,10,15,30,45,60,90]"
        ]
    )
    func unusableStoredSleepTimerPresetsLoadAsDefaults(storedValue: String) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(LocalPreferenceRecord(
            key: PlaybackSettingsStore.sleepTimerPresetsPreferenceKey,
            value: storedValue
        ))
        try context.save()
        var saveCount = 0
        let store = PlaybackSettingsStore(save: { context in
            saveCount += 1
            try context.save()
        })

        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())

        #expect(store.sleepTimerPresets == SleepTimerPresetDuration.defaults)
        #expect(store.lastErrorMessage == nil)
        #expect(saveCount == 0)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.sleepTimerPresetsPreferenceKey,
            modelContext: ModelContext(container)
        )?.value == storedValue)
    }

    @Test(
        "A sleep timer preset save failure restores the shared context without discarding other edits",
        arguments: [nil, "[20,10,15,30,45,60]"] as [String?]
    )
    func sleepTimerPresetSaveFailureRollsBackAndSurfacesError(storedValue: String?) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let previousUpdatedAt = Date(timeIntervalSince1970: 1_000)
        if let storedValue {
            context.insert(LocalPreferenceRecord(
                key: PlaybackSettingsStore.sleepTimerPresetsPreferenceKey,
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
        let previousPresets = store.sleepTimerPresets

        let didPersist = store.setSleepTimerPreset(.ninety, at: 2, modelContext: context)

        #expect(!didPersist)
        #expect(store.sleepTimerPresets == previousPresets)
        #expect(store.lastErrorMessage?.contains("Unable to update sleep timer presets") == true)

        let restoredRecord = try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.sleepTimerPresetsPreferenceKey,
            modelContext: context
        )
        #expect(restoredRecord?.value == storedValue)
        #expect(restoredRecord?.updatedAt == (storedValue == nil ? nil : previousUpdatedAt))

        try context.save()
        let freshContext = ModelContext(container)
        let reloadedStore = PlaybackSettingsStore()
        reloadedStore.load(modelContext: freshContext, playback: PlaybackVoiceBoostControllerSpy())
        #expect(reloadedStore.sleepTimerPresets == previousPresets)
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

@MainActor
private final class SkipSoundLookupRecorder {
    private(set) var sounds: [SkipSound] = []

    func url(for sound: SkipSound) -> URL? {
        sounds.append(sound)
        return SkipSoundCatalog.url(for: sound, in: .main)
    }
}
