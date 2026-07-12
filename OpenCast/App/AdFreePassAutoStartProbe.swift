#if DEBUG
import Foundation
import SwiftData

enum AdFreePassAutoStartProbe {
    nonisolated static let requestArgument = "--adfreepass-autostart-current"
    nonisolated static let requestEnvironmentKey = "OPENCAST_ADFREEPASS_AUTOSTART_CURRENT"
    nonisolated static let episodeTitleArgument = "--adfreepass-autostart-episode-title"
    nonisolated static let episodeTitleEnvironmentKey = "OPENCAST_ADFREEPASS_AUTOSTART_EPISODE_TITLE"
    nonisolated static let resetTargetArgument = "--adfreepass-autostart-reset-target"
    nonisolated static let resetTargetEnvironmentKey = "OPENCAST_ADFREEPASS_AUTOSTART_RESET_TARGET"
    nonisolated static let transcriptionEngineArgument = "--adfreepass-transcription-engine"
    nonisolated static let transcriptionEngineEnvironmentKey = "OPENCAST_ADFREEPASS_TRANSCRIPTION_ENGINE"
    nonisolated static let subscribeFeedURLArgument = "--adfreepass-autostart-subscribe-feed-url"
    nonisolated static let subscribeFeedURLEnvironmentKey = "OPENCAST_ADFREEPASS_AUTOSTART_SUBSCRIBE_FEED_URL"
    nonisolated static let installModelArgument = "--adfreepass-autostart-install-model"
    nonisolated static let installModelEnvironmentKey = "OPENCAST_ADFREEPASS_AUTOSTART_INSTALL_MODEL"

    private static let pollInterval: Duration = .seconds(1)
    private static let maxAttempts = 30

    nonisolated static var isRequested: Bool {
        let processInfo = ProcessInfo.processInfo
        let arguments = Set(processInfo.arguments)
        return arguments.contains(requestArgument)
            || processInfo.environment[requestEnvironmentKey] == "1"
    }

    @MainActor
    static func startWhenReady(
        appModel: OpenCastAppModel,
        modelContext: ModelContext,
        isInitialSetupComplete: @escaping @MainActor () -> Bool
    ) async {
        AdFreePassBackgroundRunLog.record("autostart requested")
        var didSubscribeToRequestedFeed = false
        for attempt in 1...maxAttempts {
            if Task.isCancelled {
                AdFreePassBackgroundRunLog.record("autostart cancelled")
                return
            }

            guard isInitialSetupComplete() else {
                await sleepBeforeRetry(attempt: attempt)
                continue
            }

            if let requestedSubscribeFeedURL, !didSubscribeToRequestedFeed {
                didSubscribeToRequestedFeed = true
                do {
                    try await appModel.library.subscribe(to: requestedSubscribeFeedURL, modelContext: modelContext)
                    AdFreePassBackgroundRunLog.record("autostart subscribed feedURL=\(requestedSubscribeFeedURL)")
                } catch {
                    AdFreePassBackgroundRunLog.record(
                        "autostart subscribe failed feedURL=\(requestedSubscribeFeedURL) error=\(error.localizedDescription)"
                    )
                }
            }

            guard let episode = selectedEpisode(in: appModel) else {
                guard didSubscribeToRequestedFeed, attempt < maxAttempts else {
                    AdFreePassBackgroundRunLog.record("autostart no current episode after setup")
                    return
                }
                await sleepBeforeRetry(attempt: attempt)
                continue
            }

            if shouldResetTarget {
                appModel.deleteEpisodeAdAnalysis(episodeID: episode.episodeID, modelContext: modelContext)
                appModel.deleteEpisodeTranscript(episodeID: episode.episodeID, modelContext: modelContext)
                AdFreePassBackgroundRunLog.record("autostart reset target episodeTitle=\(episode.title)")
            }

            if appModel.playback.currentEpisode?.id.rawValue != episode.episodeID {
                do {
                    try appModel.playEpisode(episode, modelContext: modelContext)
                } catch {
                    AdFreePassBackgroundRunLog.record(
                        "autostart play failed episodeTitle=\(episode.title) error=\(error.localizedDescription)"
                    )
                    return
                }
            }

            let transcriptionEngine = requestedTranscriptionEngine ?? .productDefault
            if transcriptionEngine == .whisperTiny {
                _ = appModel.setTranscriptionModelChoice(.fastTinyEnglish, modelContext: modelContext)
            }

            if shouldInstallModel, !isModelInstalled(appModel.transcriptionModels.state) {
                _ = appModel.setTranscriptionModelChoice(.fastTinyEnglish, modelContext: modelContext)
                guard appModel.installTranscriptionModel() else {
                    AdFreePassBackgroundRunLog.record("autostart model install start failed")
                    return
                }
                AdFreePassBackgroundRunLog.record("autostart model install started")
                for installAttempt in 1...240 {
                    if isModelInstalled(appModel.transcriptionModels.state) {
                        break
                    }
                    if case .failed(let message) = appModel.transcriptionModels.state {
                        AdFreePassBackgroundRunLog.record("autostart model install failed error=\(message)")
                        return
                    }
                    if installAttempt == 240 {
                        AdFreePassBackgroundRunLog.record("autostart model install timed out")
                        return
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                AdFreePassBackgroundRunLog.record("autostart model install finished")
            }

            AdFreePassBackgroundRunLog.record(
                "autostart starting episodeTitle=\(episode.title) engine=\(transcriptionEngine.logDescription)"
            )
            appModel.startOrContinueAdFreePassForCurrentEpisode(
                modelContext: modelContext,
                transcriptionEngine: transcriptionEngine
            )
            return
        }

        AdFreePassBackgroundRunLog.record("autostart timed out waiting for setup")
    }

    @MainActor
    private static func selectedEpisode(in appModel: OpenCastAppModel) -> EpisodeListItemSnapshot? {
        guard let requestedEpisodeTitle else {
            guard let episodeID = appModel.playback.currentEpisode?.id.rawValue else {
                return nil
            }
            return appModel.library.episode(with: episodeID)
        }

        let episode = appModel.library.episodes.first {
            $0.title.localizedStandardContains(requestedEpisodeTitle)
        }
        if episode == nil {
            AdFreePassBackgroundRunLog.record("autostart target not found title=\(requestedEpisodeTitle)")
        }
        return episode
    }

    @MainActor
    private static func isModelInstalled(_ state: TranscriptionModelState) -> Bool {
        if case .installed = state {
            return true
        }
        return false
    }

    @MainActor
    private static func sleepBeforeRetry(attempt: Int) async {
        AdFreePassBackgroundRunLog.record("autostart waiting for setup attempt=\(attempt)")
        do {
            try await Task.sleep(for: pollInterval)
        } catch {
            AdFreePassBackgroundRunLog.record("autostart sleep cancelled")
        }
    }

    private nonisolated static var requestedSubscribeFeedURL: String? {
        let processInfo = ProcessInfo.processInfo
        return argumentValue(from: processInfo.arguments, flag: subscribeFeedURLArgument)
            ?? processInfo.environment[subscribeFeedURLEnvironmentKey]
    }

    private nonisolated static var requestedEpisodeTitle: String? {
        let processInfo = ProcessInfo.processInfo
        return argumentValue(from: processInfo.arguments, flag: episodeTitleArgument)
            ?? processInfo.environment[episodeTitleEnvironmentKey]
    }

    private nonisolated static var shouldInstallModel: Bool {
        let processInfo = ProcessInfo.processInfo
        let value = argumentValue(from: processInfo.arguments, flag: installModelArgument)
            ?? processInfo.environment[installModelEnvironmentKey]
        return boolValue(from: value, defaultValue: false)
    }

    private nonisolated static var shouldResetTarget: Bool {
        let processInfo = ProcessInfo.processInfo
        let value = argumentValue(from: processInfo.arguments, flag: resetTargetArgument)
            ?? processInfo.environment[resetTargetEnvironmentKey]
        return boolValue(from: value, defaultValue: false)
    }

    private static var requestedTranscriptionEngine: AdFreePassTranscriptionEngine? {
        let processInfo = ProcessInfo.processInfo
        let value = argumentValue(from: processInfo.arguments, flag: transcriptionEngineArgument)
            ?? processInfo.environment[transcriptionEngineEnvironmentKey]
        let engine = AdFreePassTranscriptionEngine.benchmarkValue(from: value)
        if value != nil, engine == nil {
            AdFreePassBackgroundRunLog.record("autostart engine ignored value=\(value ?? "")")
        }
        return engine
    }

    private nonisolated static func argumentValue(from arguments: [String], flag: String) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }

    private nonisolated static func boolValue(from value: String?, defaultValue: Bool) -> Bool {
        guard let value else {
            return defaultValue
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return defaultValue
        }
    }
}
#endif
