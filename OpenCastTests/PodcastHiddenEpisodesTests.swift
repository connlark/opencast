import Testing
@testable import OpenCast

@Suite("Podcast hidden episodes")
struct PodcastHiddenEpisodesTests {
    @Test("The caption names what a Group by Podcast visit hides, and is absent while it hides nothing")
    func caption() {
        #expect(PodcastHiddenEpisodes().caption == nil)
        // Word for word what the visit said before archiving existed; UI tests read it.
        #expect(PodcastHiddenEpisodes(queued: true).caption == "Episodes playing or in Up Next are hidden")
        #expect(PodcastHiddenEpisodes(archived: true).caption == "Archived episodes are hidden")
        #expect(
            PodcastHiddenEpisodes(archived: true, queued: true).caption
                == "Episodes archived, playing or in Up Next are hidden"
        )
        // A visit from the archive view lists only archived episodes.
        #expect(PodcastHiddenEpisodes(unarchived: true).caption == "Only archived episodes are shown")
        #expect(
            PodcastHiddenEpisodes(queued: true, unarchived: true).caption
                == "Only archived episodes not playing or in Up Next are shown"
        )
        #expect(PodcastHiddenEpisodes(queued: true).systemImage == "text.line.first.and.arrowtriangle.forward")
        #expect(PodcastHiddenEpisodes(archived: true).systemImage == "archivebox")
        #expect(PodcastHiddenEpisodes(unarchived: true).systemImage == "archivebox")
        #expect(PodcastHiddenEpisodes(queued: true, unarchived: true).systemImage == "archivebox")
    }

    @Test("Under All Episodes the filtered-empty copy names what is hidden")
    func allEpisodesFilteredEmptyDescription() {
        #expect(
            PodcastHiddenEpisodes(queued: true).filteredEmptyDescription(filter: .all)
                == "Every episode in this podcast is playing or in Up Next."
        )
        #expect(
            PodcastHiddenEpisodes(archived: true).filteredEmptyDescription(filter: .all)
                == "Every episode in this podcast is archived."
        )
        #expect(
            PodcastHiddenEpisodes(archived: true, queued: true).filteredEmptyDescription(filter: .all)
                == "Every episode in this podcast is archived, playing or in Up Next."
        )
        #expect(
            PodcastHiddenEpisodes().filteredEmptyDescription(filter: .all)
                == PodcastEpisodeFilter.all.emptyStateDescription
        )
        #expect(
            PodcastHiddenEpisodes(unarchived: true).filteredEmptyDescription(filter: .all)
                == "No archived episodes to show."
        )
        #expect(
            PodcastHiddenEpisodes(queued: true, unarchived: true).filteredEmptyDescription(filter: .all)
                == "No archived episodes to show. Episodes playing or in Up Next are hidden."
        )
    }

    /// The hidden rows may be what emptied the list, so another filter's
    /// own claim (for Unplayed, that every episode is played) is dropped
    /// while anything is hidden, and kept word for word while nothing is.
    @Test("Under another filter the copy keeps the filter's words only while nothing is hidden")
    func otherFilterFilteredEmptyDescription() {
        let noneToShow: [PodcastEpisodeFilter: String] = [
            .unplayed: "No unplayed episodes to show.",
            .inProgress: "No episodes in progress to show.",
            .played: "No played episodes to show.",
            .downloaded: "No downloaded episodes to show."
        ]
        let hiddenSentences: [(PodcastHiddenEpisodes, String)] = [
            (PodcastHiddenEpisodes(archived: true), "Archived episodes are hidden."),
            (PodcastHiddenEpisodes(queued: true), "Episodes playing or in Up Next are hidden."),
            (PodcastHiddenEpisodes(archived: true, queued: true), "Episodes archived, playing or in Up Next are hidden."),
            (PodcastHiddenEpisodes(unarchived: true), "Only archived episodes are shown."),
            (
                PodcastHiddenEpisodes(queued: true, unarchived: true),
                "Only archived episodes not playing or in Up Next are shown."
            )
        ]
        for (filter, noneToShow) in noneToShow {
            #expect(PodcastHiddenEpisodes.noneToShow(under: filter) == noneToShow)
            #expect(PodcastHiddenEpisodes().filteredEmptyDescription(filter: filter) == filter.emptyStateDescription)
            for (hiddenEpisodes, hiddenSentence) in hiddenSentences {
                let description = hiddenEpisodes.filteredEmptyDescription(filter: filter)
                #expect(description == "\(noneToShow) \(hiddenSentence)")
                #expect(!description.contains(filter.emptyStateDescription))
            }
        }
        #expect(
            PodcastHiddenEpisodes().filteredEmptyDescription(filter: .unplayed)
                == "Every episode in this podcast is marked as played."
        )
    }
}
