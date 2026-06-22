import SwiftData
import SwiftUI

struct EpisodeRowButton: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var playFeedback = 0

    let episode: EpisodeListItemSnapshot
    var searchResult: EpisodeSearchResult?
    var selectsEpisodeDetailOnPlay = false
    var onSelect: () -> Void = {}
    let onOpenEpisode: (String) -> Void

    var body: some View {
        Button(action: openEpisode) {
            EpisodeRowView(episode: episode, searchResult: searchResult)
        }
        .buttonStyle(.plain)
        .modifier(
            EpisodeRowContextMenuModifier(
                episode: episode,
                onViewDetails: viewEpisodeDetails
            )
        )
        .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
        .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: episode.episodeID))
    }

    private func openEpisode() {
        nowPlayingProbeMark("playepisode-tap")
        onSelect()
        selectEpisodeDetailIfRequested()
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

    private func selectEpisodeDetailIfRequested() {
        guard selectsEpisodeDetailOnPlay else {
            return
        }

        onOpenEpisode(episode.episodeID)
    }
}
