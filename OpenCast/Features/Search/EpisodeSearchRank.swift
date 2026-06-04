import Foundation

enum EpisodeSearchRank: Int, Sendable {
    case exactVisible
    case exactSummary
    case exactShowNotes
    case fuzzyVisible
    case fuzzySummary
    case fuzzyShowNotes

    var usesHiddenText: Bool {
        switch self {
        case .exactVisible, .fuzzyVisible:
            false
        case .exactSummary, .exactShowNotes, .fuzzySummary, .fuzzyShowNotes:
            true
        }
    }
}
