import Foundation

struct EpisodeSearchRequestKey: Equatable, Sendable {
    let query: String
    let mode: EpisodeSearchMode
    let corpus: EpisodeSearchCorpusKey

    init(
        episodes: [EpisodeListItemSnapshot],
        query: String,
        mode: EpisodeSearchMode
    ) {
        self.query = query
        self.mode = mode
        corpus = EpisodeSearchCorpusKey(episodes: episodes)
    }
}
