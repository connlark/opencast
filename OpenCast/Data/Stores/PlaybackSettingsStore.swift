import Foundation
import Observation
import SwiftData

@Observable
final class PlaybackSettingsStore {
    static let voiceBoostModePreferenceKey = "playback.voiceBoost.mode"
    private static let voiceBoostEpisodeKeyPrefix = "playback.voiceBoost.episode."
    private static let skipBackwardIntervalKey = "playback.skip.backward"
    private static let skipForwardIntervalKey = "playback.skip.forward"

    private(set) var voiceBoostMode = VoiceBoostMode.globalOn
    private(set) var isVoiceBoostEnabled = true
    private(set) var currentEpisodeID: String?
    private(set) var currentPodcastID: String?
    private(set) var skipBackwardOption = PlaybackSkipIntervalOption.defaultBackward
    private(set) var skipForwardOption = PlaybackSkipIntervalOption.defaultForward
    private(set) var lastErrorMessage: String?

    var canChangeCurrentEpisodeVoiceBoost: Bool {
        voiceBoostMode == .perEpisode && currentEpisodeID != nil
    }

    func load(
        episodeID: String? = nil,
        podcastID: String? = nil,
        modelContext: ModelContext,
        playback: any PlaybackSettingsControlling
    ) {
        currentEpisodeID = episodeID
        currentPodcastID = podcastID

        do {
            voiceBoostMode = try storedVoiceBoostMode(modelContext: modelContext)
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
            isVoiceBoostEnabled = try resolvedVoiceBoostEnabled(
                episodeID: episodeID,
                modelContext: modelContext
            )
            lastErrorMessage = nil
        } catch {
            voiceBoostMode = .globalOn
            skipBackwardOption = .defaultBackward
            skipForwardOption = .defaultForward
            isVoiceBoostEnabled = true
            lastErrorMessage = "Unable to load playback settings: \(error.localizedDescription)"
        }

        apply(to: playback)
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
            try modelContext.save()
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
            try modelContext.save()
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
            return .globalOn
        }

        return VoiceBoostMode(rawValue: rawValue) ?? .globalOn
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
            try modelContext.save()
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
