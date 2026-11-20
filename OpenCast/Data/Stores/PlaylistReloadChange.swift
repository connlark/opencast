nonisolated struct PlaylistReloadChange: Equatable, Sendable {
    /// Memory was republished.
    var didChange = false
    var removedPlaylistIDs: Set<String> = []
    var renamedPlaylistIDs: Set<String> = []
    /// The rows hold twins, or rows a tombstone shadows, that repair has not removed yet.
    var needsRepair = false
}
