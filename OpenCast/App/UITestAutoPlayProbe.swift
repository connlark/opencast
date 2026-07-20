import Foundation
import SwiftData

/// Starts playback of a seeded episode at launch so perf harnesses can measure
/// steady-state playback without UI automation. UI-testing mode only.
enum UITestAutoPlayProbe {
    nonisolated static let episodeTitleEnvironmentKey = "OPENCAST_UI_TEST_AUTOPLAY_EPISODE_TITLE"

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

        for _ in 1...maxAttempts {
            if Task.isCancelled {
                return
            }

            guard isInitialSetupComplete(),
                  let episode = appModel.library.episodes.first(where: {
                      $0.title.localizedStandardContains(requestedEpisodeTitle)
                  })
            else {
                try? await Task.sleep(for: pollInterval)
                continue
            }

            do {
                try appModel.playEpisode(episode, modelContext: modelContext)
            } catch {
                appModel.lastPlaybackError = "UI test auto-play failed: \(error.localizedDescription)"
            }
            return
        }
    }

    private nonisolated static var requestedEpisodeTitle: String? {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("--opencast-ui-testing")
            || processInfo.environment["OPENCAST_UI_TESTING"] == "1"
        else {
            return nil
        }

        guard let title = processInfo.environment[episodeTitleEnvironmentKey], !title.isEmpty else {
            return nil
        }
        return title
    }
}
