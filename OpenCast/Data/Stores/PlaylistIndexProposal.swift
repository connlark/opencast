import FoundationModels

/// One playlist in a simpler answer: episode numbers only. The app names it.
@Generable
nonisolated struct PlaylistIndexProposal: Equatable, Sendable {
    @Guide(.maximumCount(30))
    var episodeIndices: [Int]
}
