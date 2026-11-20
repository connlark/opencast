import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Inbox filtered-empty copy")
struct InboxFilteredEmptyStateCopyTests {
    private static let otherFilters: [PodcastEpisodeFilter] = [.unplayed, .inProgress, .played, .downloaded]
    private static let noneToShow: [PodcastEpisodeFilter: String] = [
        .unplayed: "No unplayed episodes to show.",
        .inProgress: "No episodes in progress to show.",
        .played: "No played episodes to show.",
        .downloaded: "No downloaded episodes to show."
    ]

    @Test(
        "Another filter says none are left to show, and what is hidden, while something is hidden",
        arguments: [
            (PodcastEpisodeFilter.unplayed, PodcastHiddenEpisodes(queued: true), "No unplayed episodes to show. Episodes playing or in Up Next are hidden."),
            (.downloaded, PodcastHiddenEpisodes(archived: true), "No downloaded episodes to show. Archived episodes are hidden.")
        ] as [(PodcastEpisodeFilter, PodcastHiddenEpisodes, String)]
    )
    func otherFiltersNameWhatIsHidden(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes, description: String) {
        #expect(InboxFilteredEmptyStateView.description(filter: filter, hiddenEpisodes: hiddenEpisodes) == description)
    }

    @Test(
        "The Inbox view offers Show All Episodes while the filter or Hide Up Next hides rows, and Show Archived while the archive does",
        // Filter, what is hidden, offers Show All Episodes, offers Show Archived.
        arguments: [
            (PodcastEpisodeFilter.all, PodcastHiddenEpisodes(archived: true), false, true),
            (.all, PodcastHiddenEpisodes(archived: true, queued: true), true, true),
            (.all, PodcastHiddenEpisodes(queued: true), true, false),
            (.unplayed, PodcastHiddenEpisodes(), true, false),
            (.downloaded, PodcastHiddenEpisodes(archived: true), true, true),
            (.played, PodcastHiddenEpisodes(queued: true), true, false),
            (.inProgress, PodcastHiddenEpisodes(archived: true, queued: true), true, true)
        ] as [(PodcastEpisodeFilter, PodcastHiddenEpisodes, Bool, Bool)]
    )
    func inboxViewButtons(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes, showAll: Bool, showArchived: Bool) {
        #expect(InboxFilteredEmptyStateView.offersShowAllEpisodes(filter: filter, hiddenEpisodes: hiddenEpisodes) == showAll)
        #expect(InboxFilteredEmptyStateView.offersShowArchived(hiddenEpisodes: hiddenEpisodes) == showArchived)
    }

    @Test("What each view hides follows the archived Inbox episodes")
    func hiddenEpisodesFollowTheArchivedInboxEpisodes() {
        let inboxEpisodes = ["kept", "archived"].map { id in
            EpisodeListItemSnapshot.fixture(episodeID: id, audioURL: nil, guid: id)
        }
        func hidden(hidesQueued: Bool, showsArchived: Bool, archived: Set<String>) -> PodcastHiddenEpisodes {
            InboxFilteredEmptyStateView.hiddenEpisodes(
                inboxEpisodes: inboxEpisodes,
                hidesQueuedEpisodes: hidesQueued,
                showsArchivedEpisodes: showsArchived,
                archivedEpisodeIDs: archived
            )
        }
        let outsideTheInbox: Set = ["unfollowed-show-episode"]

        #expect(hidden(hidesQueued: false, showsArchived: false, archived: ["archived"]) == PodcastHiddenEpisodes(archived: true))
        #expect(hidden(hidesQueued: true, showsArchived: false, archived: []) == PodcastHiddenEpisodes(queued: true))
        #expect(hidden(hidesQueued: true, showsArchived: false, archived: outsideTheInbox) == PodcastHiddenEpisodes(queued: true))
        #expect(
            hidden(hidesQueued: true, showsArchived: false, archived: ["archived"])
                == PodcastHiddenEpisodes(archived: true, queued: true)
        )
        #expect(
            InboxFilteredEmptyStateView.description(
                filter: .all,
                hiddenEpisodes: hidden(hidesQueued: true, showsArchived: false, archived: [])
            ) == "Every episode in your Inbox is playing or in Up Next."
        )

        // The archive view never hides the archive itself.
        #expect(hidden(hidesQueued: true, showsArchived: true, archived: ["archived"]) == PodcastHiddenEpisodes(queued: true))
        #expect(hidden(hidesQueued: true, showsArchived: true, archived: []) == PodcastHiddenEpisodes())
        #expect(hidden(hidesQueued: true, showsArchived: true, archived: outsideTheInbox) == PodcastHiddenEpisodes())
        #expect(hidden(hidesQueued: false, showsArchived: true, archived: ["archived"]) == PodcastHiddenEpisodes())
    }

    @Test("The empty archive says where archived episodes go under All, and none are left under another filter")
    func archiveViewCopy() {
        #expect(
            InboxArchiveEmptyStateView.description(filter: .all, hiddenEpisodes: PodcastHiddenEpisodes())
                == "Episodes you archive from the Inbox are kept here."
        )
        #expect(
            InboxArchiveEmptyStateView.description(filter: .all, hiddenEpisodes: PodcastHiddenEpisodes(queued: true))
                == "Every archived episode is playing or in Up Next."
        )
        for filter in Self.otherFilters {
            let noneToShow = Self.noneToShow[filter] ?? ""
            #expect(
                InboxArchiveEmptyStateView.description(filter: filter, hiddenEpisodes: PodcastHiddenEpisodes())
                    == noneToShow
            )
            #expect(
                InboxArchiveEmptyStateView.description(filter: filter, hiddenEpisodes: PodcastHiddenEpisodes(queued: true))
                    == "\(noneToShow) Episodes playing or in Up Next are hidden."
            )
        }
    }
}
