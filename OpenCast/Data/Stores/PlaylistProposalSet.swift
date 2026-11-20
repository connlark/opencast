import FoundationModels

/// No `@Guide` descriptions: the instructions already spell out every field, and adding them
/// changes the prompt the model sees.
@Generable
nonisolated struct PlaylistProposalSet: Equatable, Sendable {
    @Guide(.maximumCount(12))
    var playlists: [PlaylistProposal]
}
