/// What a playlist reload changed, and whether the stored rows still hold
/// something duplicate repair would remove.
nonisolated struct PlaylistReloadChange: Equatable, Sendable {
    /// Memory was republished.
    var didChange = false
    /// Listed before the reload and gone after it.
    var removedPlaylistIDs: Set<String> = []
    /// Listed before and after with a different name.
    var renamedPlaylistIDs: Set<String> = []
    /// The rows hold twins, or rows a tombstone shadows, that repair has not removed yet.
    var needsRepair = false
}
