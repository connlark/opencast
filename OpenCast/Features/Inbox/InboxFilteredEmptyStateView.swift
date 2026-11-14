import SwiftUI

/// The Inbox view has episodes, but the filter, Hide Up Next and the
/// archive leave none to show. The archive view's own empty state is
/// `InboxArchiveEmptyStateView`.
struct InboxFilteredEmptyStateView: View {
    let filter: PodcastEpisodeFilter
    let hiddenEpisodes: PodcastHiddenEpisodes
    let onShowAll: () -> Void
    let onShowArchived: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(filter.emptyStateTitle, systemImage: filter.systemImage)
        } description: {
            Text(Self.description(filter: filter, hiddenEpisodes: hiddenEpisodes))
        } actions: {
            // The two targets meet edge to edge, keeping the pair as close
            // as it reads without them.
            VStack(spacing: 0) {
                if Self.offersShowAllEpisodes(filter: filter, hiddenEpisodes: hiddenEpisodes) {
                    Button(action: onShowAll) {
                        Text("Show All Episodes")
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                }
                if Self.offersShowArchived(hiddenEpisodes: hiddenEpisodes) {
                    Button(action: onShowArchived) {
                        Text("Show Archived")
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                }
            }
        }
        // The Inbox shows this as a List row, where default-style buttons
        // make the whole row one tap target that fires every one of them.
        // Borderless buttons take only their own taps, so each label carries
        // its own 44 pt target.
        .buttonStyle(.borderless)
        .accessibilityIdentifier("Inbox Filtered Empty")
    }

    /// What either view of the Inbox hides when its list is empty. The
    /// Inbox view hides its archived episodes, named only while at least
    /// one is archived so the copy never names an empty archive, and Up Next
    /// while Hide Up Next is on. The archive view names Up Next only while
    /// archived episodes exist for it to hide: an empty archive is not
    /// Hide Up Next's doing.
    static func hiddenEpisodes(
        inboxEpisodes: [EpisodeListItemSnapshot],
        hidesQueuedEpisodes: Bool,
        showsArchivedEpisodes: Bool,
        archivedEpisodeIDs: Set<String>
    ) -> PodcastHiddenEpisodes {
        let hasArchivedEpisodes = inboxEpisodes.contains { archivedEpisodeIDs.contains($0.episodeID) }
        return showsArchivedEpisodes
            ? PodcastHiddenEpisodes(queued: hidesQueuedEpisodes && hasArchivedEpisodes)
            : PodcastHiddenEpisodes(archived: hasArchivedEpisodes, queued: hidesQueuedEpisodes)
    }

    /// Show All Episodes resets the filter and Hide Up Next, so it is
    /// offered only while one of them can be what hides the rows.
    static func offersShowAllEpisodes(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes) -> Bool {
        filter != .all || hiddenEpisodes.queued
    }

    /// Show Archived opens the archive view, offered while archived Inbox
    /// episodes are among what is hidden.
    static func offersShowArchived(hiddenEpisodes: PodcastHiddenEpisodes) -> Bool {
        hiddenEpisodes.archived
    }

    /// Under All Episodes only what is hidden can empty the Inbox, so the
    /// copy names it. Another filter keeps its own copy while nothing is
    /// hidden, and otherwise says none are left to show and what is hidden.
    static func description(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes) -> String {
        guard filter == .all else {
            return hiddenEpisodes.filteredEmptyDescription(hiddenUnder: filter) ?? filter.inboxEmptyStateDescription
        }
        return switch (hiddenEpisodes.archived, hiddenEpisodes.queued) {
        case (true, true):
            "Every episode in your Inbox is archived, playing or in Up Next."
        case (true, false):
            "Every episode in your Inbox is archived."
        case (false, true):
            "Every episode in your Inbox is playing or in Up Next."
        case (false, false):
            filter.inboxEmptyStateDescription
        }
    }
}
