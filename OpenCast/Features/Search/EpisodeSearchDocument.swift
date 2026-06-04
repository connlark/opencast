import Foundation

struct EpisodeSearchDocument: Sendable {
    let episodeID: String
    let sourceIndex: Int
    let title: String
    let podcastTitle: String
    let summaryHTML: String?
    let showNotesHTML: String?
}
