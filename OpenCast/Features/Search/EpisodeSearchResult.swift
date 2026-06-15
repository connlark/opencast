import Foundation

struct EpisodeSearchResult: Identifiable {
    let episode: EpisodeListItemSnapshot
    let highlightedTitle: AttributedString
    let highlightedPodcastTitle: AttributedString
    let snippet: AttributedString?

    var id: String {
        episode.episodeID
    }
}
