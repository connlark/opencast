import SwiftData
import SwiftUI

struct PodcastEpisodeSwipeActionsModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot

    func body(content: Content) -> some View {
        // State reads live inside the swipe-action builders, which SwiftUI
        // evaluates on reveal — the row body never pays the record lookup or
        // the completed-download file stat (perf 21 / sync-data I).
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                let isCurrentlyPlaying = appModel.playback.currentEpisode?.id.rawValue == episode.episodeID
                Button(
                    "Play Next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    action: enqueueNext
                )
                .tint(.orange)
                .disabled(isCurrentlyPlaying)

                let downloadState = appModel.downloadMenuState(for: episode)
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

    private func enqueueNext() {
        appModel.performUpNextQueueMutation {
            appModel.upNextQueue.enqueueNext(episode, modelContext: modelContext)
        }
    }
}
