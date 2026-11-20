import FoundationModels

/// Property order is the schema order the instructions describe. The schema caps
/// `episodeIndices` because the model ignores the instructions' "up to 30" and writes slow
/// answers of 150 or more indices.
@Generable
nonisolated struct PlaylistProposal: Equatable, Sendable {
    var title: String
    var rationale: String
    @Guide(.maximumCount(30))
    var episodeIndices: [Int]
    var confidence: Double
}
