import Foundation

struct EpisodeSearchMatch: Sendable {
    let episodeID: String
    let sourceIndex: Int
    let rank: EpisodeSearchRank
    let titleTerms: [String]
    let podcastTitleTerms: [String]
    let summaryTerms: [String]
    let showNotesTerms: [String]
}
