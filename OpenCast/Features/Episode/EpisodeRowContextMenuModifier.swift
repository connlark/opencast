import SwiftData
import SwiftUI

struct EpisodeRowContextMenuModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot
    let onViewDetails: (EpisodeListItemSnapshot) -> Void

    func body(content: Content) -> some View {
        let isPlayed = appModel.library.progressRecord(for: episode.episodeID)?.isPlayed == true

        content.contextMenu {
            Button("View Episode Details", systemImage: "info.circle", action: viewDetails)
            Button(
                isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle",
                action: togglePlayed
            )
            downloadButton
            detectAdsButton
        } preview: {
            EpisodeContextPreviewView(episode: episode)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        let state = appModel.downloadMenuState(for: episode)
        if state.showsDownloadAction {
            Button("Download", systemImage: "arrow.down.circle", action: download)
                .disabled(!state.isDownloadActionEnabled)
        }
    }

    private var detectAdsButton: some View {
        let state = appModel.detectAdsMenuState(for: episode)
        return Button(state.title, systemImage: "megaphone", action: detectAds)
            .disabled(!state.isEnabled)
    }

    private func viewDetails() {
        onViewDetails(episode)
    }

    private func download() {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }

    private func togglePlayed() {
        appModel.toggleEpisodePlayed(episode, modelContext: modelContext)
    }

    private func detectAds() {
        appModel.startAdFreePass(for: episode, modelContext: modelContext)
    }
}
