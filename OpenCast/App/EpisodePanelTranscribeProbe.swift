#if DEBUG
import Foundation
import SwiftData

/// DEBUG probe for the episode transcript panel path: invokes the exact
/// app-model action behind the panel's Generate button
/// (`transcribeDownloadedEpisode`) for a downloaded episode, so the panel's
/// engine resolution can be device-proven without physical taps.
enum EpisodePanelTranscribeProbe {
    nonisolated static let episodeTitleArgument = "--opencast-panel-transcribe-episode-title"
    nonisolated static let episodeTitleEnvironmentKey = "OPENCAST_PANEL_TRANSCRIBE_EPISODE_TITLE"

    private static let pollInterval: Duration = .seconds(1)
    private static let maxAttempts = 30

    nonisolated static var isRequested: Bool {
        requestedEpisodeTitle != nil
    }

    @MainActor
    static func startWhenReady(
        appModel: OpenCastAppModel,
        modelContext: ModelContext,
        isInitialSetupComplete: @escaping @MainActor () -> Bool
    ) async {
        guard let requestedEpisodeTitle else {
            return
        }

        AdFreePassBackgroundRunLog.record("panel transcribe probe requested title=\(requestedEpisodeTitle)")
        for attempt in 1...maxAttempts {
            if Task.isCancelled {
                return
            }

            guard isInitialSetupComplete() else {
                try? await Task.sleep(for: pollInterval)
                continue
            }

            guard let episode = appModel.library.episodes.first(where: {
                $0.title.localizedStandardContains(requestedEpisodeTitle)
            }) else {
                AdFreePassBackgroundRunLog.record("panel transcribe probe target not found attempt=\(attempt)")
                try? await Task.sleep(for: pollInterval)
                continue
            }

            guard let downloadRecord = appModel.downloads.record(for: episode.episodeID),
                  downloadRecord.state == .completed
            else {
                AdFreePassBackgroundRunLog.record("panel transcribe probe download not ready attempt=\(attempt)")
                try? await Task.sleep(for: pollInterval)
                continue
            }

            AdFreePassBackgroundRunLog.record("panel transcribe probe starting episodeTitle=\(episode.title)")
            appModel.transcribeDownloadedEpisode(
                episode,
                downloadRecord: downloadRecord,
                modelContext: modelContext
            )
            return
        }

        AdFreePassBackgroundRunLog.record("panel transcribe probe timed out")
    }

    private nonisolated static var requestedEpisodeTitle: String? {
        let processInfo = ProcessInfo.processInfo
        for (index, argument) in processInfo.arguments.enumerated() {
            if argument.hasPrefix("\(episodeTitleArgument)=") {
                return String(argument.dropFirst(episodeTitleArgument.count + 1))
            }
            if argument == episodeTitleArgument, processInfo.arguments.indices.contains(index + 1) {
                return processInfo.arguments[index + 1]
            }
        }
        return processInfo.environment[episodeTitleEnvironmentKey]
    }
}
#endif
