import Foundation

/// Everything a smart playlist's evaluation depends on. A token the rule
/// does not read stays nil, so an unrelated change never recomputes it and a
/// view reading the key never observes it.
nonisolated struct SmartPlaylistEvaluationKey: Hashable, Sendable {
    let ruleJSON: String
    /// `LibraryStore.episodeSearchCorpusRevision`: moves with every episode
    /// list publication.
    let episodeRevision: Int
    /// `LibraryStore.progressChangeRevision`, when the rule filters on
    /// played state.
    let progressRevision: Int?
    /// `DownloadStore.recordsRevision`, when the rule is Downloaded Only.
    let downloadsRevision: Int?
    /// `LibraryStore.newEpisodeReferenceDate`, when the rule has an age
    /// clause.
    let referenceDate: Date?
}
