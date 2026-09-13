#if DEBUG
import Foundation
import SwiftData

/// Delivers completion during the dismissal exit without racing audio duration
/// against XCTest's variable launch, accessibility and gesture latency.
enum UITestNowPlayingCompletionFixture {
    static func installIfRequested(appModel: OpenCastAppModel, modelContext: ModelContext) {
        guard ProcessInfo.processInfo.environment["OPENCAST_UI_TEST_COMPLETE_DURING_DISMISSAL"] == "1",
              NowPlayingFramePacingProbe.shared.isEnabled
        else {
            return
        }

        NowPlayingFramePacingProbe.shared.onMark = { [weak appModel] label in
            guard label == "dismiss-drag-ended" else { return }
            NowPlayingFramePacingProbe.shared.onMark = nil
            // The current actor turn starts the exit animation. Deliver the
            // same app completion callback on the next turn while it is active.
            Task { @MainActor [weak appModel] in
                guard let appModel, let episode = appModel.playback.currentEpisode else { return }
                nowPlayingProbeMark("completion-fixture-triggered")
                appModel.handlePlaybackEpisodeFinished(episode, policy: .stop, modelContext: modelContext)
            }
        }
    }
}
#endif
