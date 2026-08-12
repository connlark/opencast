import Foundation

struct EpisodeSearchResult: Identifiable {
    let episode: EpisodeListItemSnapshot
    let highlightedTitle: AttributedString
    let highlightedPodcastTitle: AttributedString
    let snippet: AttributedString?
    let transcriptStartTime: TimeInterval?

    init(
        episode: EpisodeListItemSnapshot,
        highlightedTitle: AttributedString,
        highlightedPodcastTitle: AttributedString,
        snippet: AttributedString?,
        transcriptStartTime: TimeInterval? = nil
    ) {
        self.episode = episode
        self.highlightedTitle = highlightedTitle
        self.highlightedPodcastTitle = highlightedPodcastTitle
        self.snippet = snippet
        self.transcriptStartTime = transcriptStartTime
    }

    var id: String {
        episode.episodeID
    }
}
