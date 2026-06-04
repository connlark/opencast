import Foundation

struct EpisodeSearchResult: Identifiable {
    let episode: EpisodeCacheRecord
    let highlightedTitle: AttributedString
    let highlightedPodcastTitle: AttributedString
    let snippet: AttributedString?

    var id: String {
        episode.episodeID
    }
}
