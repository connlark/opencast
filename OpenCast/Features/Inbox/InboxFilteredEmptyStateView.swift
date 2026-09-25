import SwiftUI

/// The Inbox has episodes, but the filter and the Hide Up Next toggle leave
/// none to show.
struct InboxFilteredEmptyStateView: View {
    let filter: PodcastEpisodeFilter
    let hidesQueuedEpisodes: Bool
    let onShowAll: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(filter.emptyStateTitle, systemImage: filter.systemImage)
        } description: {
            Text(description)
        } actions: {
            Button("Show All Episodes", action: onShowAll)
        }
        .accessibilityIdentifier("Inbox Filtered Empty")
    }

    private var description: String {
        switch (filter, hidesQueuedEpisodes) {
        case (.all, _):
            "Every episode in your Inbox is in Up Next."
        case (_, false):
            filter.inboxEmptyStateDescription
        case (_, true):
            "\(filter.inboxEmptyStateDescription) Episodes in Up Next are hidden."
        }
    }
}
