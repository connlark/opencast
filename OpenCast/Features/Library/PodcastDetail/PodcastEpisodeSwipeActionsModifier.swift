import SwiftData
import SwiftUI

struct PodcastEpisodeSwipeActionsModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot
    var showsArchiveAction = false

    func body(content: Content) -> some View {
        // State reads stay inside the swipe-action builders, which SwiftUI evaluates on reveal, so
        // the row body never pays the record lookup or the download file stat.
        content
            .swipeActions(edge: .leading) {
                let isPlayed = appModel.library.progressRecord(for: episode.episodeID)?.isPlayed == true
                Button(
                    isPlayed ? "Mark Unplayed" : "Mark Played",
                    systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle",
                    action: togglePlayed
                )
                .tint(isPlayed ? .blue : .green)
            }
            // A swipe action draws a disabled button exactly like an enabled one, so an action
            // that cannot run is left out rather than disabled.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if appModel.playback.currentEpisode?.id.rawValue != episode.episodeID {
                    Button(
                        "Play Next",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        action: enqueueNext
                    )
                    .tint(.orange)
                }

                if showsArchiveAction {
                    EpisodeArchiveButton(
                        episode: episode,
                        isArchived: appModel.library.isArchived(episodeID: episode.episodeID)
                    )
                    .tint(.gray)
                }

                if appModel.downloadMenuState(for: episode).isDownloadActionEnabled {
                    Button("Download", systemImage: "arrow.down.circle", action: download)
                        .tint(.blue)
                }
            }
    }

    private func togglePlayed() {
        appModel.toggleEpisodePlayed(episode, modelContext: modelContext)
    }

    private func download() {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }

    private func enqueueNext() {
        appModel.enqueueInUpNext(episode, at: .next, modelContext: modelContext)
    }
}
