import OpenCastCore
import SwiftData
import SwiftUI

struct PodcastPreviewSampleButton: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: Episode

    var body: some View {
        let isCurrent = appModel.playback.currentEpisode?.id == episode.id
        let showsPause = isCurrent && appModel.playback.state.showsPauseButton
        let timeLeft = isCurrent ? timeLeft : nil

        Button(action: playOrToggle) {
            Label(timeLeft ?? "Latest", systemImage: showsPause ? "pause.fill" : "play.fill")
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.glass)
        .accessibilityLabel(showsPause ? "Pause Latest Episode" : "Play Latest Episode")
        .accessibilityValue(timeLeft ?? "")
        .accessibilityInputLabels(["Latest", showsPause ? "Pause" : "Play"])
        .accessibilityIdentifier("Podcast Preview Latest")
    }

    private var timeLeft: String? {
        guard let duration = appModel.playback.duration ?? episode.duration else {
            return nil
        }
        let remaining = duration - appModel.playback.position
        guard Int(exactly: (max(remaining, 0) / 60).rounded(.up)) != nil else {
            return nil
        }
        return remaining.formattedEpisodeRemaining
    }

    private func playOrToggle() {
        guard appModel.playback.currentEpisode?.id != episode.id else {
            appModel.playback.togglePlayPause()
            return
        }
        do {
            try appModel.playEpisode(
                EpisodeListItemSnapshot(episode: episode),
                presentsNowPlaying: false,
                requeuesCurrentEpisode: true,
                modelContext: modelContext
            )
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }
}
