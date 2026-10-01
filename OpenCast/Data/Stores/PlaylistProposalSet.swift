import FoundationModels

/// The structured answer to one Make a Playlist request. The schema carries
/// no descriptions because the instructions already spell out every field;
/// adding them changes the prompt the model sees.
@Generable
nonisolated struct PlaylistProposalSet: Equatable, Sendable {
    @Guide(.maximumCount(12))
    var playlists: [PlaylistProposal]
}
