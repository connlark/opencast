import SwiftData
import SwiftUI

struct EpisodeRowButton: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var playFeedback = 0

    let episode: EpisodeListItemSnapshot
    var searchResult: EpisodeSearchResult?
    var showsLocalStatusBadges = false
    var showsGoToShow = true
    var onSelect: () -> Void = {}
    let onOpenEpisode: (String) -> Void

    var body: some View {
        Button(action: primaryAction) {
            EpisodeRowView(
                episode: episode,
                searchResult: searchResult,
                showsLocalStatusBadges: showsLocalStatusBadges,
                onPlay: playButtonAction
            )
        }
        .buttonStyle(.plain)
        .modifier(
            EpisodeRowContextMenuModifier(
                episode: episode,
                showsGoToShow: showsGoToShow,
                onViewDetails: viewEpisodeDetails
            )
        )
        .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
        .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: episode.episodeID))
    }

    /// With Tap to Play off the row opens the episode, so the trailing glyph
    /// becomes the play button.
    private var playButtonAction: (() -> Void)? {
        guard !appModel.playbackSettings.isTapToPlayEnabled else {
            return nil
        }
        return playEpisode
    }

    private func primaryAction() {
        if appModel.playbackSettings.isTapToPlayEnabled {
            playEpisode()
        } else {
            viewEpisodeDetails(episode)
        }
    }

    private func playEpisode() {
        nowPlayingProbeMark("playepisode-tap")
        onSelect()
        do {
            try appModel.playEpisode(episode, modelContext: modelContext)
            playFeedback += 1
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    private func viewEpisodeDetails(_ episode: EpisodeListItemSnapshot) {
        onSelect()
        onOpenEpisode(episode.episodeID)
    }
}
