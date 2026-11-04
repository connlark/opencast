import SwiftUI

/// The Up Next tab's root content: the queue (`UpNextQueueContent`, the
/// sheet's and the pane's list without their stack) inside the tab's
/// two-pane root. A row opens its episode (the detail's root in the split, a
/// push in the stack) and neither plays nor dismisses anything; playing
/// stays on the episode's page. The list keeps the tab accessory's
/// clearance from its own viewport, as every scrolling root does.
struct UpNextRootContent: View {
    @State private var activeAlert: UpNextQueueAlert?

    let onOpenEpisode: (String) -> Void

    /// The route a queue row opens in the tab.
    static func route(forQueuedEpisode episodeID: String) -> AppRoute {
        .episodeDetail(id: episodeID)
    }

    var body: some View {
        UpNextQueueContent(activeAlert: $activeAlert) { episode in
            onOpenEpisode(episode.episodeID)
        }
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
}
