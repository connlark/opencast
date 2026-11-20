import Foundation
import Observation
import OpenCastPlayback
import SwiftData

@Observable
final class PlaybackSettingsStore {
    static let playbackRatePreferenceKey = "playback.rate"
    static let voiceBoostModePreferenceKey = "playback.voiceBoost.mode"
    static let autoSkipPromosAndAdsPreferenceKey = "playback.autoSkipPromosAndAds"
    static let autoSkipSoundPreferenceKey = "playback.autoSkipSound"
    static let customSkipSoundFilePreferenceKey = "playback.autoSkipSound.customFile"
    static let customSkipSoundNamePreferenceKey = "playback.autoSkipSound.customName"
    static let privateNoteButtonsPreferenceKey = "playback.privateNotes.showButtons"
    static let tapToPlayPreferenceKey = "playback.episodeRow.tapToPlay"
    static let requeueInterruptedEpisodePreferenceKey = "playback.upNext.requeueInterruptedEpisode"
    static let sleepTimerPresetsPreferenceKey = "playback.sleepTimer.presets"
    private static let voiceBoostEpisodeKeyPrefix = "playback.voiceBoost.episode."
    private static let skipBackwardIntervalKey = "playback.skip.backward"
    private static let skipForwardIntervalKey = "playback.skip.forward"

    private(set) var voiceBoostMode = VoiceBoostMode.defaultMode
    private(set) var isVoiceBoostEnabled = true
    private(set) var currentEpisodeID: String?
    private(set) var currentPodcastID: String?
    private(set) var skipBackwardOption = PlaybackSkipIntervalOption.defaultBackward
    private(set) var skipForwardOption = PlaybackSkipIntervalOption.defaultForward
    private(set) var isAutoSkipPromosAndAdsEnabled = true
    /// nil is the None choice. Kept while Auto-Skip is off.
    private(set) var autoSkipSound: SkipSound?
    /// Loaded when it is the choice or the picker opens. Whenever `autoSkipSound` is the custom
    /// sound, this holds it.
    private(set) var customSkipSound: CustomSkipSound?
    private(set) var showsPrivateNoteButtons = false
    private(set) var isTapToPlayEnabled = true
    private(set) var isRequeueInterruptedEpisodeEnabled = false
    /// Six distinct slots in the listener's order, unsorted.
    private(set) var sleepTimerPresets = SleepTimerPresetDuration.defaults
    private(set) var lastErrorMessage: String?
    /// Differs from `playback.rate` while a show's own speed applies.
    private(set) var globalPlaybackRate: Float = 1
    @ObservationIgnored private let save: (ModelContext) throws -> Void
    @ObservationIgnored private let skipSoundURL: @MainActor (SkipSound) -> URL?
    @ObservationIgnored let customSkipSoundFiles: CustomSkipSoundFiles
    /// Counts Delete Data resets, so an import that was in flight across one
    /// is discarded.
    @ObservationIgnored private var dataNukeGeneration = 0
    /// While nonzero, nothing sweeps the directory: an import may have moved its file in before
    /// saving the preference that references it.
    @ObservationIgnored private var customSkipSoundImportsInFlight = 0

    init(
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        skipSoundURL: @escaping @MainActor (SkipSound) -> URL? = { SkipSoundCatalog.url(for: $0, in: .main) },
        customSkipSoundFiles: CustomSkipSoundFiles = CustomSkipSoundFiles()
    ) {
        self.save = save
        self.skipSoundURL = skipSoundURL
        self.customSkipSoundFiles = customSkipSoundFiles
    }

    var canChangeCurrentEpisodeVoiceBoost: Bool {
        voiceBoostMode == .perEpisode && currentEpisodeID != nil
    }

    func load(
        episodeID: String? = nil,
        podcastID: String? = nil,
        rateOverride: Float? = nil,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) {
        currentEpisodeID = episodeID
        currentPodcastID = podcastID

        do {
            voiceBoostMode = try storedVoiceBoostMode(modelContext: modelContext)
            let playbackRate = try storedPlaybackRate(modelContext: modelContext)
            skipBackwardOption = try storedSkipOption(
                key: Self.skipBackwardIntervalKey,
                defaultOption: .defaultBackward,
                modelContext: modelContext
            )
            skipForwardOption = try storedSkipOption(
                key: Self.skipForwardIntervalKey,
                defaultOption: .defaultForward,
                modelContext: modelContext
            )
            isAutoSkipPromosAndAdsEnabled = try booleanPreference(
                key: Self.autoSkipPromosAndAdsPreferenceKey,
                modelContext: modelContext
            ) ?? true
            try loadAutoSkipSound(modelContext: modelContext)
            showsPrivateNoteButtons = try booleanPreference(
                key: Self.privateNoteButtonsPreferenceKey,
                modelContext: modelContext
            ) ?? false
            isTapToPlayEnabled = try booleanPreference(
                key: Self.tapToPlayPreferenceKey,
                modelContext: modelContext
            ) ?? true
            isRequeueInterruptedEpisodeEnabled = try booleanPreference(
                key: Self.requeueInterruptedEpisodePreferenceKey,
                modelContext: modelContext
            ) ?? false
            sleepTimerPresets = try storedSleepTimerPresets(modelContext: modelContext)
            isVoiceBoostEnabled = try resolvedVoiceBoostEnabled(
                episodeID: episodeID,
                modelContext: modelContext
            )
            globalPlaybackRate = playbackRate
            playback.setRate(rateOverride ?? playbackRate)
            lastErrorMessage = nil
        } catch {
            voiceBoostMode = .defaultMode
            skipBackwardOption = .defaultBackward
            skipForwardOption = .defaultForward
            isAutoSkipPromosAndAdsEnabled = true
            autoSkipSound = nil
            isTapToPlayEnabled = true
            isRequeueInterruptedEpisodeEnabled = false
            sleepTimerPresets = SleepTimerPresetDuration.defaults
            showsPrivateNoteButtons = false
            isVoiceBoostEnabled = true
            globalPlaybackRate = 1
            playback.setRate(1)
            lastErrorMessage = "Unable to load playback settings: \(error.localizedDescription)"
        }

        apply(to: playback)
    }

    /// Whether to save compares with the stored target, not `playback.rate`: the speed playing can
    /// differ from the one stored for its scope.
    @discardableResult
    func setPlaybackRate(
        _ rate: Float,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling,
        persist: ((Float, ModelContext) throws -> Void)? = nil
    ) -> Bool {
        let rate = PlaybackRateSteps.clamped(rate)
        let previousRate = playback.rate
        let savesGlobalRate = persist == nil && globalPlaybackRate != rate
        guard persist != nil || savesGlobalRate || previousRate != rate else {
            return true
        }

        if previousRate != rate {
            playback.setRate(rate)
        }

        do {
            if let persist {
                try persist(rate, modelContext)
            } else if savesGlobalRate {
                try persistPreference(
                    String(rate),
                    key: Self.playbackRatePreferenceKey,
                    modelContext: modelContext
                )
                globalPlaybackRate = rate
            }
            lastErrorMessage = nil
            return true
        } catch {
            if playback.rate != previousRate {
                playback.setRate(previousRate)
            }
            lastErrorMessage = (error as? PodcastPlaybackRateSaveError)?.message
                ?? "Unable to update playback speed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setVoiceBoostMode(
        _ mode: VoiceBoostMode,
        episodeID: String?,
        podcastID: String?,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        let previousMode = voiceBoostMode
        let previousValue = isVoiceBoostEnabled

        voiceBoostMode = mode
        currentEpisodeID = episodeID
        currentPodcastID = podcastID

        do {
            try LocalPreferenceRecord.upsert(
                key: Self.voiceBoostModePreferenceKey,
                value: mode.rawValue,
                modelContext: modelContext
            )
            isVoiceBoostEnabled = try resolvedVoiceBoostEnabled(
                episodeID: episodeID,
                modelContext: modelContext
            )
            try save(modelContext)
            applyVoiceBoost(to: playback)
            lastErrorMessage = nil
            return true
        } catch {
            voiceBoostMode = previousMode
            isVoiceBoostEnabled = previousValue
            applyVoiceBoost(to: playback)
            lastErrorMessage = "Unable to update Voice Boost mode: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setVoiceBoostEnabled(
        _ isEnabled: Bool,
        forEpisodeID episodeID: String,
        podcastID: String?,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        let previousEpisodeID = currentEpisodeID
        let previousPodcastID = currentPodcastID
        let previousValue = isVoiceBoostEnabled

        currentEpisodeID = episodeID
        currentPodcastID = podcastID

        guard voiceBoostMode == .perEpisode else {
            isVoiceBoostEnabled = previousValue
            lastErrorMessage = nil
            applyVoiceBoost(to: playback)
            return false
        }

        isVoiceBoostEnabled = isEnabled
        applyVoiceBoost(to: playback)

        do {
            try LocalPreferenceRecord.upsert(
                key: voiceBoostEpisodePreferenceKey(episodeID),
                value: isEnabled.description,
                modelContext: modelContext
            )
            try save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            currentEpisodeID = previousEpisodeID
            currentPodcastID = previousPodcastID
            isVoiceBoostEnabled = previousValue
            applyVoiceBoost(to: playback)
            lastErrorMessage = "Unable to update Voice Boost for this episode: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setAutoSkipPromosAndAdsEnabled(
        _ isEnabled: Bool,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        guard isAutoSkipPromosAndAdsEnabled != isEnabled else {
            return true
        }

        let previousValue = isAutoSkipPromosAndAdsEnabled
        isAutoSkipPromosAndAdsEnabled = isEnabled
        applyAutoSkip(to: playback)

        do {
            try LocalPreferenceRecord.upsert(
                key: Self.autoSkipPromosAndAdsPreferenceKey,
                value: isEnabled.description,
                modelContext: modelContext
            )
            try save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            isAutoSkipPromosAndAdsEnabled = previousValue
            applyAutoSkip(to: playback)
            lastErrorMessage = "Unable to update auto-skip: \(error.localizedDescription)"
            return false
        }
    }

    /// Plays the sound even when it is already the choice, so the picker can audition it.
    @discardableResult
    func setAutoSkipSound(
        _ sound: SkipSound?,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        guard sound?.id != SkipSoundCatalog.customID || sound == customSkipSound?.skipSound else {
            return false
        }

        if autoSkipSound != sound {
            let previousSound = autoSkipSound
            autoSkipSound = sound
            applyAutoSkipCue(to: playback)

            do {
                try persistPreference(
                    sound?.id ?? "",
                    key: Self.autoSkipSoundPreferenceKey,
                    modelContext: modelContext
                )
                lastErrorMessage = nil
            } catch {
                autoSkipSound = previousSound
                applyAutoSkipCue(to: playback)
                lastErrorMessage = "Unable to update the skip sound: \(error.localizedDescription)"
                return false
            }
        }

        if let sound, let url = soundURL(for: sound) {
            playback.previewAutoSkipCue(url)
        }
        return true
    }

    func loadCustomSkipSound(modelContext: ModelContext) {
        do {
            let stored = try storedCustomSkipSound(modelContext: modelContext)
            removeUnreferencedCustomSkipSoundFiles(keeping: stored?.fileName)
            customSkipSound = stored.flatMap { customSkipSoundFiles.fileExists(named: $0.fileName) ? $0 : nil }
        } catch {
            lastErrorMessage = "Unable to load your skip sound: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func importCustomSkipSound(
        from source: URL,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) async throws(CustomSkipSoundImportError) -> Bool {
        let nukeGeneration = dataNukeGeneration
        let imported = try await importCustomSkipSoundFile(from: source)
        guard dataNukeGeneration == nukeGeneration else {
            removeCustomSkipSoundFile(named: imported.fileName)
            return false
        }

        let replacedFileName: String?
        do {
            replacedFileName = try preferenceRecord(
                key: Self.customSkipSoundFilePreferenceKey,
                modelContext: modelContext
            )?.value
            try persistPreferences(
                [
                    (Self.autoSkipSoundPreferenceKey, SkipSoundCatalog.customID),
                    (Self.customSkipSoundFilePreferenceKey, imported.fileName),
                    (Self.customSkipSoundNamePreferenceKey, imported.name),
                ],
                modelContext: modelContext
            )
        } catch {
            lastErrorMessage = "Unable to add the sound: \(error.localizedDescription)"
            removeCustomSkipSoundFile(named: imported.fileName)
            return false
        }

        customSkipSound = imported
        autoSkipSound = imported.skipSound
        applyAutoSkipCue(to: playback)
        lastErrorMessage = nil
        if let replacedFileName {
            removeCustomSkipSoundFile(named: replacedFileName)
        }
        removeUnreferencedCustomSkipSoundFiles(keeping: imported.fileName)
        playback.previewAutoSkipCue(customSkipSoundFiles.url(forFileName: imported.fileName))
        return true
    }

    private func importCustomSkipSoundFile(from source: URL) async throws(CustomSkipSoundImportError) -> CustomSkipSound {
        customSkipSoundImportsInFlight += 1
        defer { customSkipSoundImportsInFlight -= 1 }
        return try await customSkipSoundFiles.importSound(from: source)
    }

    /// Preferences go before the file: a failed file delete leaves only an unreferenced file,
    /// which the next sweep removes.
    @discardableResult
    func removeCustomSkipSound(
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        let fileName: String?
        do {
            fileName = try preferenceRecord(
                key: Self.customSkipSoundFilePreferenceKey,
                modelContext: modelContext
            )?.value
            var cleared: [(key: String, value: String)] = [
                (Self.customSkipSoundFilePreferenceKey, ""),
                (Self.customSkipSoundNamePreferenceKey, ""),
            ]
            if try preferenceRecord(key: Self.autoSkipSoundPreferenceKey, modelContext: modelContext)?.value
                == SkipSoundCatalog.customID {
                cleared.append((Self.autoSkipSoundPreferenceKey, ""))
            }
            try persistPreferences(cleared, modelContext: modelContext)
        } catch {
            lastErrorMessage = "Unable to delete the sound: \(error.localizedDescription)"
            return false
        }

        customSkipSound = nil
        lastErrorMessage = nil
        if autoSkipSound?.id == SkipSoundCatalog.customID {
            autoSkipSound = nil
            applyAutoSkipCue(to: playback)
        }
        if let fileName {
            removeCustomSkipSoundFile(named: fileName)
        }
        return true
    }

    func resetAfterDataNuke() {
        customSkipSound = nil
        dataNukeGeneration += 1
    }

    @discardableResult
    func setTapToPlayEnabled(
        _ isEnabled: Bool,
        modelContext: ModelContext
    ) -> Bool {
        updateBooleanPreference(
            isEnabled,
            key: Self.tapToPlayPreferenceKey,
            current: \.isTapToPlayEnabled,
            assign: { isTapToPlayEnabled = $0 },
            failureDescription: "episode tap behavior",
            modelContext: modelContext
        )
    }

    @discardableResult
    func setRequeueInterruptedEpisodeEnabled(
        _ isEnabled: Bool,
        modelContext: ModelContext
    ) -> Bool {
        updateBooleanPreference(
            isEnabled,
            key: Self.requeueInterruptedEpisodePreferenceKey,
            current: \.isRequeueInterruptedEpisodeEnabled,
            assign: { isRequeueInterruptedEpisodeEnabled = $0 },
            failureDescription: "Up Next behavior",
            modelContext: modelContext
        )
    }

    @discardableResult
    func setSleepTimerPreset(
        _ duration: SleepTimerPresetDuration,
        at index: Int,
        modelContext: ModelContext
    ) -> Bool {
        guard sleepTimerPresets.indices.contains(index) else {
            return false
        }
        guard sleepTimerPresets[index] != duration else {
            return true
        }
        guard !sleepTimerPresets.contains(duration) else {
            return false
        }

        let previousPresets = sleepTimerPresets
        sleepTimerPresets[index] = duration

        do {
            let data = try JSONEncoder().encode(sleepTimerPresets)
            try persistPreference(
                String(decoding: data, as: UTF8.self),
                key: Self.sleepTimerPresetsPreferenceKey,
                modelContext: modelContext
            )
            lastErrorMessage = nil
            return true
        } catch {
            sleepTimerPresets = previousPresets
            lastErrorMessage = "Unable to update sleep timer presets: \(error.localizedDescription)"
            return false
        }
    }

    private func updateBooleanPreference(
        _ isEnabled: Bool,
        key: String,
        current: KeyPath<PlaybackSettingsStore, Bool>,
        assign: (Bool) -> Void,
        failureDescription: String,
        modelContext: ModelContext
    ) -> Bool {
        guard self[keyPath: current] != isEnabled else {
            return true
        }

        let previousValue = self[keyPath: current]
        assign(isEnabled)

        do {
            try persistPreference(isEnabled.description, key: key, modelContext: modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            assign(previousValue)
            lastErrorMessage = "Unable to update \(failureDescription): \(error.localizedDescription)"
            return false
        }
    }

    private func persistPreference(
        _ value: String,
        key: String,
        modelContext: ModelContext
    ) throws {
        try persistPreferences([(key, value)], modelContext: modelContext)
    }

    /// Writes every value in one save, or none of them.
    private func persistPreferences(
        _ values: [(key: String, value: String)],
        modelContext: ModelContext
    ) throws {
        var undoEdits: [() -> Void] = []
        do {
            for (key, value) in values {
                let existingRecord = try LocalPreferenceRecord.preference(
                    forKey: key,
                    modelContext: modelContext
                )
                let record = existingRecord ?? LocalPreferenceRecord(key: key, value: value)
                let previousStoredValue = record.value
                let previousUpdatedAt = record.updatedAt
                if existingRecord == nil {
                    modelContext.insert(record)
                }
                record.value = value
                record.updatedAt = .now
                undoEdits.append {
                    if existingRecord != nil {
                        record.value = previousStoredValue
                        record.updatedAt = previousUpdatedAt
                    } else {
                        modelContext.delete(record)
                    }
                }
            }
            try save(modelContext)
        } catch {
            // Undo only these preferences; the shared context can contain
            // unrelated edits that must survive a failed save.
            for undo in undoEdits.reversed() {
                undo()
            }
            throw error
        }
    }

    @discardableResult
    func setPrivateNoteButtonsEnabled(
        _ isEnabled: Bool,
        modelContext: ModelContext
    ) -> Bool {
        updateBooleanPreference(
            isEnabled,
            key: Self.privateNoteButtonsPreferenceKey,
            current: \.showsPrivateNoteButtons,
            assign: { showsPrivateNoteButtons = $0 },
            failureDescription: "the Private Notes setting",
            modelContext: modelContext
        )
    }

    @discardableResult
    func setSkipBackwardOption(
        _ option: PlaybackSkipIntervalOption,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        updateSkipOption(
            option,
            key: Self.skipBackwardIntervalKey,
            current: \.skipBackwardOption,
            assign: { skipBackwardOption = $0 },
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setSkipForwardOption(
        _ option: PlaybackSkipIntervalOption,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        updateSkipOption(
            option,
            key: Self.skipForwardIntervalKey,
            current: \.skipForwardOption,
            assign: { skipForwardOption = $0 },
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func removeVoiceBoostPreferences(
        forEpisodeIDs episodeIDs: [String],
        modelContext: ModelContext
    ) -> Bool {
        guard !episodeIDs.isEmpty else {
            return true
        }

        let keys = Set(episodeIDs.map(voiceBoostEpisodePreferenceKey))
        do {
            let records = try modelContext.fetch(
                FetchDescriptor<LocalPreferenceRecord>(
                    predicate: #Predicate { record in
                        keys.contains(record.key)
                    }
                )
            )
            guard !records.isEmpty else {
                return true
            }

            for record in records {
                modelContext.delete(record)
            }
            try save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to remove Voice Boost settings: \(error.localizedDescription)"
            return false
        }
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    private func resolvedVoiceBoostEnabled(
        episodeID: String?,
        modelContext: ModelContext
    ) throws -> Bool {
        switch voiceBoostMode {
        case .globalOn:
            true
        case .globalOff:
            false
        case .perEpisode:
            try voiceBoostEnabledForEpisode(episodeID, modelContext: modelContext)
        }
    }

    private func voiceBoostEnabledForEpisode(
        _ episodeID: String?,
        modelContext: ModelContext
    ) throws -> Bool {
        guard let episodeID else {
            return true
        }

        return try booleanPreference(
            key: voiceBoostEpisodePreferenceKey(episodeID),
            modelContext: modelContext
        ) ?? true
    }

    private func storedVoiceBoostMode(modelContext: ModelContext) throws -> VoiceBoostMode {
        guard let rawValue = try preferenceRecord(
            key: Self.voiceBoostModePreferenceKey,
            modelContext: modelContext
        )?.value else {
            return .defaultMode
        }

        return VoiceBoostMode(rawValue: rawValue) ?? .defaultMode
    }

    private func loadAutoSkipSound(modelContext: ModelContext) throws {
        let id = try preferenceRecord(
            key: Self.autoSkipSoundPreferenceKey,
            modelContext: modelContext
        )?.value
        guard id == SkipSoundCatalog.customID else {
            autoSkipSound = id.flatMap(SkipSoundCatalog.sound(id:))
            return
        }

        customSkipSound = try storedCustomSkipSound(modelContext: modelContext)
        autoSkipSound = customSkipSound?.skipSound
    }

    private func storedCustomSkipSound(modelContext: ModelContext) throws -> CustomSkipSound? {
        guard let fileName = try preferenceRecord(
            key: Self.customSkipSoundFilePreferenceKey,
            modelContext: modelContext
        )?.value,
            let name = try preferenceRecord(
                key: Self.customSkipSoundNamePreferenceKey,
                modelContext: modelContext
            )?.value,
            !fileName.isEmpty,
            !name.isEmpty
        else {
            return nil
        }

        return CustomSkipSound(fileName: fileName, name: name)
    }

    private func removeCustomSkipSoundFile(named fileName: String) {
        do {
            try customSkipSoundFiles.removeFile(named: fileName)
        } catch {
            lastErrorMessage = "Unable to delete a skip sound file: \(error.localizedDescription)"
        }
    }

    /// Skipped while an import is in flight; that import sweeps once it succeeds.
    private func removeUnreferencedCustomSkipSoundFiles(keeping fileName: String?) {
        guard customSkipSoundImportsInFlight == 0 else {
            return
        }
        do {
            try customSkipSoundFiles.removeFiles(except: fileName)
        } catch {
            lastErrorMessage = "Unable to delete a skip sound file: \(error.localizedDescription)"
        }
    }

    private func storedPlaybackRate(modelContext: ModelContext) throws -> Float {
        guard let value = try preferenceRecord(
            key: Self.playbackRatePreferenceKey,
            modelContext: modelContext
        )?.value,
              let rate = Float(value)
        else {
            return 1
        }

        return PlaybackRateSteps.clamped(rate)
    }

    private func storedSkipOption(
        key: String,
        defaultOption: PlaybackSkipIntervalOption,
        modelContext: ModelContext
    ) throws -> PlaybackSkipIntervalOption {
        guard let value = try preferenceRecord(key: key, modelContext: modelContext)?.value,
              let seconds = Int(value),
              let option = PlaybackSkipIntervalOption(rawValue: seconds)
        else {
            return defaultOption
        }

        return option
    }

    private func storedSleepTimerPresets(modelContext: ModelContext) throws -> [SleepTimerPresetDuration] {
        guard let value = try preferenceRecord(
            key: Self.sleepTimerPresetsPreferenceKey,
            modelContext: modelContext
        )?.value,
              let presets = try? JSONDecoder().decode([SleepTimerPresetDuration].self, from: Data(value.utf8)),
              presets.count == SleepTimerPresetDuration.defaults.count,
              Set(presets).count == presets.count
        else {
            return SleepTimerPresetDuration.defaults
        }

        return presets
    }

    private func updateSkipOption(
        _ option: PlaybackSkipIntervalOption,
        key: String,
        current: KeyPath<PlaybackSettingsStore, PlaybackSkipIntervalOption>,
        assign: (PlaybackSkipIntervalOption) -> Void,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) -> Bool {
        guard self[keyPath: current] != option else {
            return true
        }

        let previousOption = self[keyPath: current]
        assign(option)
        applySkipIntervals(to: playback)

        do {
            try LocalPreferenceRecord.upsert(
                key: key,
                value: "\(option.rawValue)",
                modelContext: modelContext
            )
            try save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            assign(previousOption)
            applySkipIntervals(to: playback)
            lastErrorMessage = "Unable to update skip interval: \(error.localizedDescription)"
            return false
        }
    }

    private func apply(to playback: any PlaybackSettingsControlling) {
        applyVoiceBoost(to: playback)
        applySkipIntervals(to: playback)
        applyAutoSkip(to: playback)
    }

    private func applyVoiceBoost(to playback: any PlaybackSettingsControlling) {
        playback.setVoiceBoostEnabled(isVoiceBoostEnabled)
    }

    private func applySkipIntervals(to playback: any PlaybackSettingsControlling) {
        playback.setSkipIntervals(
            backward: skipBackwardOption.seconds,
            forward: skipForwardOption.seconds
        )
    }

    /// The cue goes first: switching Auto-Skip on inside a zone skips at
    /// once, and that skip should carry the sound.
    private func applyAutoSkip(to playback: any PlaybackSettingsControlling) {
        applyAutoSkipCue(to: playback)
        playback.setAutoSkipEnabled(isAutoSkipPromosAndAdsEnabled)
    }

    private func applyAutoSkipCue(to playback: any PlaybackSettingsControlling) {
        guard isAutoSkipPromosAndAdsEnabled, let autoSkipSound else {
            playback.setAutoSkipCue(nil)
            return
        }

        let url = soundURL(for: autoSkipSound)
        if url == nil, autoSkipSound.id == SkipSoundCatalog.customID {
            self.autoSkipSound = nil
            customSkipSound = nil
        }
        playback.setAutoSkipCue(url)
    }

    private func soundURL(for sound: SkipSound) -> URL? {
        guard sound.id == SkipSoundCatalog.customID else {
            return skipSoundURL(sound)
        }
        guard let customSkipSound, customSkipSoundFiles.fileExists(named: customSkipSound.fileName) else {
            return nil
        }

        return customSkipSoundFiles.url(forFileName: customSkipSound.fileName)
    }

    private func booleanPreference(
        key: String,
        modelContext: ModelContext
    ) throws -> Bool? {
        guard let value = try preferenceRecord(key: key, modelContext: modelContext)?.value else {
            return nil
        }

        return switch value {
        case "true":
            true
        case "false":
            false
        default:
            nil
        }
    }

    private func preferenceRecord(
        key: String,
        modelContext: ModelContext
    ) throws -> LocalPreferenceRecord? {
        try LocalPreferenceRecord.preference(forKey: key, modelContext: modelContext)
    }

    private func voiceBoostEpisodePreferenceKey(_ episodeID: String) -> String {
        Self.voiceBoostEpisodeKeyPrefix + episodeID
    }
}
