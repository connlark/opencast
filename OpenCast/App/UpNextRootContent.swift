import SwiftData
import SwiftUI

/// The Up Next tab's root content: the queue (`UpNextQueueContent`, the
/// sheet's and the pane's list without their stack) inside the tab's
/// two-pane root. What a row does is `rowAction`. The list keeps the tab
/// accessory's clearance from its own viewport, as every scrolling root does.
struct UpNextRootContent: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var activeAlert: UpNextQueueAlert?

    let rowAction: RowAction
    let onOpenEpisode: (String) -> Void

    enum RowAction: Equatable {
        /// Plays the episode where it is, as the Up Next sheet's row does,
        /// without presenting Now Playing; the tab stays in front.
        case play
        /// Opens the episode: the detail's root in the split, a push in the
        /// stack. Playing stays on the episode's page.
        case openEpisode
    }

    /// A row plays on a scene that has not reported a fold; a foldable
    /// scene, whose open poses show the episode beside the queue, opens it.
    static func rowAction(isFoldableScene: Bool) -> RowAction {
        isFoldableScene ? .openEpisode : .play
    }

    /// The route a queue row opens in the tab.
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
