import FoundationModels

/// The model writes no words here, so Apple's output check has none to decline. No `@Guide`
/// descriptions: the instructions already spell out every field, and adding them changes the
/// prompt the model sees.
@Generable
nonisolated struct PlaylistIndexSet: Equatable, Sendable {
    @Guide(.maximumCount(12))
    var playlists: [PlaylistIndexProposal]
}
