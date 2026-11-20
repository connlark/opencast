import Testing
@testable import OpenCast

@Suite("Podcast hidden episodes")
struct PodcastHiddenEpisodesTests {
    @Test(
        "Under another filter the copy keeps the filter's words only while nothing is hidden",
        arguments: [
            (PodcastEpisodeFilter.unplayed, PodcastHiddenEpisodes(), "Every episode in this podcast is marked as played."),
            (.unplayed, PodcastHiddenEpisodes(queued: true), "No unplayed episodes to show. Episodes playing or in Up Next are hidden."),
            (.played, PodcastHiddenEpisodes(unarchived: true), "No played episodes to show. Only archived episodes are shown.")
        ] as [(PodcastEpisodeFilter, PodcastHiddenEpisodes, String)]
    )
    func otherFilterFilteredEmptyDescription(filter: PodcastEpisodeFilter, hiddenEpisodes: PodcastHiddenEpisodes, description: String) {
        #expect(hiddenEpisodes.filteredEmptyDescription(filter: filter) == description)
    }
}
