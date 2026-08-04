import SwiftData
import SwiftUI

struct DownloadedEpisodeRowButton: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var playFeedback = 0

    let item: DownloadListItem
    var searchResult: EpisodeSearchResult?
    var onSelect: () -> Void = {}
    let onOpenEpisode: (String) -> Void

    private var isPlayed: Bool {
        appModel.library.progressRecord(for: item.id)?.isPlayed == true
    }

    var body: some View {
        Button(action: playDownloadedEpisode) {
            VStack(alignment: .leading, spacing: 0) {
                EpisodeRowView(episode: item.episode, searchResult: searchResult)
                if item.isOrphaned {
                    Label("No longer in library", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 68)
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(
            EpisodeRowContextMenuModifier(
                episode: item.episode,
                showsGoToShow: true,
                onViewDetails: viewEpisodeDetails
            )
        )
        .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
        .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: item.id))
        .tag(item.id)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: deleteDownload)
        }
        .swipeActions(edge: .leading) {
            Button(
                isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle",
                action: togglePlayed
            )
            .tint(isPlayed ? .blue : .green)
        }
    }

    private func playDownloadedEpisode() {
        nowPlayingProbeMark("playepisode-tap")
        onSelect()
        do {
            try appModel.playDownloadedEpisode(
                item.episode,
                downloadRecord: item.record,
                modelContext: modelContext
            )
            playFeedback += 1
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    private func viewEpisodeDetails(_ episode: EpisodeListItemSnapshot) {
        onSelect()
        onOpenEpisode(episode.episodeID)
    }

    private func deleteDownload() {
        appModel.deleteDownload(item.record, modelContext: modelContext)
    }

    private func togglePlayed() {
        appModel.toggleEpisodePlayed(item.episode, modelContext: modelContext)
    }
}
