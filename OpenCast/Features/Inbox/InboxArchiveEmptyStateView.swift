import SwiftUI

struct InboxArchiveEmptyStateView: View {
    let filter: PodcastEpisodeFilter
    /// Only `queued` is ever set, and only while Hide Up Next hides archived episodes.
    let hiddenEpisodes: PodcastHiddenEpisodes
    let onShowInbox: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Archived Episodes", systemImage: "archivebox")
        } description: {
            Text(Self.description(filter: filter, hiddenEpisodes: hiddenEpisodes))
        } actions: {
            Button(action: onShowInbox) {
                Text("Show Inbox")
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
        }
        // A List row fires a default-style button on a tap anywhere in it; a
        // borderless one takes only its label's 44 pt target.
        .buttonStyle(.borderless)
        .accessibilityIdentifier("Inbox Archive Empty")
    }

    static func description(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes) -> String {
        guard filter == .all else {
            return hiddenEpisodes.filteredEmptyDescription(hiddenUnder: filter)
                ?? PodcastHiddenEpisodes.noneToShow(under: filter)
        }
        return hiddenEpisodes.queued
            ? "Every archived episode is playing or in Up Next."
            : "Episodes you archive from the Inbox are kept here."
    }
}
