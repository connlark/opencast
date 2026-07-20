import SwiftData
import SwiftUI

struct PodcastEpisodeSwipeActionsModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot

    func body(content: Content) -> some View {
        let isPlayed = appModel.library.progressRecord(for: episode.episodeID)?.isPlayed == true
        let downloadState = appModel.downloadMenuState(for: episode)

        content
            .swipeActions(edge: .leading) {
                Button(
                    isPlayed ? "Mark Unplayed" : "Mark Played",
                    systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle",
                    action: togglePlayed
                )
                .tint(isPlayed ? .blue : .green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if downloadState.showsDownloadAction {
                    Button("Download", systemImage: "arrow.down.circle", action: download)
                        .tint(.blue)
                        .disabled(!downloadState.isDownloadActionEnabled)
                }
            }
    }

    private func togglePlayed() {
        appModel.toggleEpisodePlayed(episode, modelContext: modelContext)
    }

    private func download() {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }
}
