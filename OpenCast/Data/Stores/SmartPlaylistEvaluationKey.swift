import Foundation

/// A token the rule does not read stays nil, so an unrelated change never recomputes the
/// evaluation and a view reading the key never observes that token.
nonisolated struct SmartPlaylistEvaluationKey: Hashable, Sendable {
    let ruleJSON: String
    let episodeRevision: Int
    let progressRevision: Int?
    let downloadsRevision: Int?
    let referenceDate: Date?
}
