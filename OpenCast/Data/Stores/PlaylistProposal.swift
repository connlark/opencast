import FoundationModels

/// One proposed playlist as the model returned it, before validation.
/// Property order is the schema order the instructions describe. The schema
/// caps `episodeIndices` at 30 because the model ignores the instructions'
/// "up to 30" and writes slow answers of 150 or more indices; with the cap,
/// a long match list answers as several playlists.
@Generable
nonisolated struct PlaylistProposal: Equatable, Sendable {
    var title: String
    var rationale: String
    @Guide(.maximumCount(30))
    var episodeIndices: [Int]
    var confidence: Double
}
