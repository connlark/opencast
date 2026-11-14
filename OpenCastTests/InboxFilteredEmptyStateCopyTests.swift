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

    @Test("Under All Episodes the copy names what is hidden")
    func allEpisodesNamesWhatIsHidden() {
        #expect(
            InboxFilteredEmptyStateView.description(filter: .all, hiddenEpisodes: PodcastHiddenEpisodes(archived: true))
                == "Every episode in your Inbox is archived."
        )
        #expect(
            InboxFilteredEmptyStateView.description(
                filter: .all,
                hiddenEpisodes: PodcastHiddenEpisodes(archived: true, queued: true)
            ) == "Every episode in your Inbox is archived, playing or in Up Next."
        )
        #expect(
            InboxFilteredEmptyStateView.description(filter: .all, hiddenEpisodes: PodcastHiddenEpisodes(queued: true))
                == "Every episode in your Inbox is playing or in Up Next."
        )
        #expect(
            InboxFilteredEmptyStateView.description(filter: .all, hiddenEpisodes: PodcastHiddenEpisodes())
                == PodcastEpisodeFilter.all.inboxEmptyStateDescription
        )
    }

    @Test("Another filter keeps its own copy while nothing is hidden")
    func otherFiltersKeepTheirCopyWhileNothingIsHidden() {
        for filter in Self.otherFilters {
            #expect(
                InboxFilteredEmptyStateView.description(filter: filter, hiddenEpisodes: PodcastHiddenEpisodes())
                    == filter.inboxEmptyStateDescription
            )
        }
        #expect(
            InboxFilteredEmptyStateView.description(filter: .unplayed, hiddenEpisodes: PodcastHiddenEpisodes())
                == "Every episode in your Inbox is marked as played."
        )
    }

    /// The hidden rows may be what emptied the list, so the filter's own
    /// claim (for Unplayed, that every episode is played) is dropped.
    @Test("Another filter says none are left to show, and what is hidden, while something is hidden")
    func otherFiltersNameWhatIsHidden() {
        let hiddenSentences: [(PodcastHiddenEpisodes, String)] = [
            (PodcastHiddenEpisodes(archived: true), "Archived episodes are hidden."),
            (PodcastHiddenEpisodes(queued: true), "Episodes playing or in Up Next are hidden."),
            (PodcastHiddenEpisodes(archived: true, queued: true), "Episodes archived, playing or in Up Next are hidden.")
        ]
        for filter in Self.otherFilters {
            for (hiddenEpisodes, hiddenSentence) in hiddenSentences {
                let description = InboxFilteredEmptyStateView.description(filter: filter, hiddenEpisodes: hiddenEpisodes)
                #expect(description == "\(Self.noneToShow[filter] ?? "") \(hiddenSentence)")
                #expect(!description.contains(filter.inboxEmptyStateDescription))
            }
        }
    }

    /// Show All Episodes resets the filter and Hide Up Next and leaves the
    /// view, so an Inbox the archive alone empties offers Show Archived and
    /// nothing else.
    @Test("The Inbox view offers Show All Episodes while the filter or Hide Up Next hides rows, and Show Archived while the archive does")
    func inboxViewButtons() {
        // Filter, what is hidden, offers Show All Episodes, offers Show Archived.
        let states: [(PodcastEpisodeFilter, PodcastHiddenEpisodes, Bool, Bool)] = [
            (.all, PodcastHiddenEpisodes(archived: true), false, true),
            (.all, PodcastHiddenEpisodes(archived: true, queued: true), true, true),
            (.all, PodcastHiddenEpisodes(queued: true), true, false),
            (.unplayed, PodcastHiddenEpisodes(), true, false),
            (.downloaded, PodcastHiddenEpisodes(archived: true), true, true),
            (.played, PodcastHiddenEpisodes(queued: true), true, false),
            (.inProgress, PodcastHiddenEpisodes(archived: true, queued: true), true, true)
        ]
        for (filter, hiddenEpisodes, showAll, showArchived) in states {
            #expect(
                InboxFilteredEmptyStateView.offersShowAllEpisodes(filter: filter, hiddenEpisodes: hiddenEpisodes) == showAll,
                "Show All Episodes under \(filter.title), \(hiddenEpisodes)"
            )
            #expect(
                InboxFilteredEmptyStateView.offersShowArchived(hiddenEpisodes: hiddenEpisodes) == showArchived,
                "Show Archived under \(filter.title), \(hiddenEpisodes)"
            )
        }
    }

    /// The archive is named only while archived Inbox episodes are hidden,
    /// as a show page names it only while the show has some. The archive
    /// view names Up Next only while archived episodes exist for it to hide.
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

        // The Inbox view.
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
