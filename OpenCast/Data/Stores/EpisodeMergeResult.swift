import Foundation

/// Outcome of the diagnostics "Merge Duplicate Episodes" sweep.
nonisolated struct EpisodeMergeResult: Equatable, Sendable {
    var feedsProcessed = 0
    var episodesMigrated = 0
    var failedFeedURLs: [String] = []

    var displayStatus: String {
        episodesMigrated > 0 ? "Merged" : "No Duplicates"
    }
}
