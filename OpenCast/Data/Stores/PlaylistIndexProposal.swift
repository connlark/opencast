import FoundationModels

@Generable
nonisolated struct PlaylistIndexProposal: Equatable, Sendable {
    @Guide(.maximumCount(30))
    var episodeIndices: [Int]
}
