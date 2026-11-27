import SwiftData
import SwiftUI

struct EpisodeRowContextMenuModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot
    let showsGoToShow: Bool
    let onViewDetails: (EpisodeListItemSnapshot) -> Void
    var showsArchiveAction = false

    @State private var modePromptEpisode: EpisodeListItemSnapshot?
    @State private var noticeGate = AnalysisKeyNoticeGate()

    func body(content: Content) -> some View {
        let isPlayed = appModel.library.progressRecord(for: episode.episodeID)?.isPlayed == true

        content
            .adDetectionModeDialog(episode: $modePromptEpisode)
            .analysisKeyNotice(gate: noticeGate)
            .contextMenu {
            Section {
                EpisodeShareMenu(episode: episode)
            }
            Button("Go to Episode", systemImage: "info.circle", action: viewDetails)
            if showsGoToShow {
                TwoPaneRootLink(route: .podcastDetail(feedURL: episode.podcastID), selectionStyle: .menuItem) {
                    Label("Go to Show", systemImage: "rectangle.stack")
                }
            }
            EpisodeUpNextMenuButtons(
                state: appModel.upNextMenuState(for: episode),
                onPlayNext: enqueueNext,
                onPlayLast: enqueueLast
            )
            Button("Add to Playlist…", systemImage: "music.note.list", action: addToPlaylist)
            Button(
                isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle",
                action: togglePlayed
            )
            if showsArchiveAction {
                EpisodeArchiveButton(
                    episode: episode,
                    isArchived: appModel.library.isArchived(episodeID: episode.episodeID)
                )
            }
            downloadButton
            detectAdsButton
        } preview: {
            EpisodeContextPreviewView(episode: episode)
                // Context previews have a separate host; explicitly supply
                // the model needed for their on-demand SQLite note lookup.
                .environment(appModel)
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

    private func enqueueNext() {
        appModel.enqueueInUpNext(episode, at: .next, modelContext: modelContext)
    }

    private func enqueueLast() {
        appModel.enqueueInUpNext(episode, at: .last, modelContext: modelContext)
    }

    private func addToPlaylist() {
        appModel.requestAddToPlaylist(episodeID: episode.episodeID)
    }

    private func detectAds() {
        noticeGate.run(appModel: appModel) {
            if appModel.startAdFreePassResolvingMode(for: episode, modelContext: modelContext) {
                modePromptEpisode = episode
            }
        }
    }
}
