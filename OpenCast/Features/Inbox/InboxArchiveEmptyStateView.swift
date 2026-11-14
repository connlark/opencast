import SwiftUI

/// The Inbox's archive view with nothing to list: nothing is archived, or
/// nothing archived is left under the filter and Hide Up Next. Show Inbox
/// returns to the Inbox view.
struct InboxArchiveEmptyStateView: View {
    let filter: PodcastEpisodeFilter
    /// Only `queued`, and only while Hide Up Next hides archived episodes
    /// (`InboxFilteredEmptyStateView.hiddenEpisodes`).
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

    /// Under All Episodes the archive is empty unless Hide Up Next hides
    /// what is in it. Another filter says none are left to show, and what is
    /// hidden.
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
