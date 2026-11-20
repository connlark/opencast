import SwiftData
import SwiftUI

struct UpNextRootContent: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var activeAlert: UpNextQueueAlert?

    let rowAction: RowAction
    let onOpenEpisode: (String) -> Void

    enum RowAction: Equatable {
        case play
        case openEpisode
    }

    static func route(forQueuedEpisode episodeID: String) -> AppRoute {
        .episodeDetail(id: episodeID)
    }

    var body: some View {
        UpNextQueueContent(activeAlert: $activeAlert, onSelectEpisode: select)
            .tabAccessoryBottomClearance()
            .twoPaneRootClearanceProbe("upnext-queue")
            .alert(
                activeAlert?.title ?? "Up Next Error",
                item: $activeAlert
            ) { _ in
            } message: { alert in
                Text(alert.message)
            }
    }

    private func select(_ episode: EpisodeListItemSnapshot) {
        switch rowAction {
        case .play:
            play(episode)
        case .openEpisode:
            onOpenEpisode(episode.episodeID)
        }
    }

    private func play(_ episode: EpisodeListItemSnapshot) {
        do {
            try appModel.playEpisode(episode, presentsNowPlaying: false, modelContext: modelContext)
        } catch {
            activeAlert = .playback(error.localizedDescription)
        }
    }
}
