import FoundationModels

/// One proposed playlist as the model returned it, before validation.
/// Property order is the schema order the instructions describe.
@Generable
nonisolated struct PlaylistProposal: Equatable, Sendable {
    var title: String
    var rationale: String
    var episodeIndices: [Int]
    var confidence: Double
}
