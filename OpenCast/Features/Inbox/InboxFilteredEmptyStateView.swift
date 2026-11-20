import SwiftUI

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
        // In a List row default-style buttons make the whole row one target that fires them all;
        // borderless ones take only their own taps.
        .buttonStyle(.borderless)
        .accessibilityIdentifier("Inbox Filtered Empty")
    }

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

    static func offersShowAllEpisodes(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes) -> Bool {
        filter != .all || hiddenEpisodes.queued
    }

    static func offersShowArchived(hiddenEpisodes: PodcastHiddenEpisodes) -> Bool {
        hiddenEpisodes.archived
    }

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
