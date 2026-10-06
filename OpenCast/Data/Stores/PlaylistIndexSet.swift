import FoundationModels

/// The structured answer to a simpler Make a Playlist request: the model
/// writes no words, so Apple's output check has none to decline. The schema
/// carries no descriptions because the instructions already spell out every
/// field; adding them changes the prompt the model sees.
@Generable
nonisolated struct PlaylistIndexSet: Equatable, Sendable {
    @Guide(.maximumCount(12))
    var playlists: [PlaylistIndexProposal]
}
