enum SyncTombstoneScope: String {
    case subscription
    case feedProgress = "feed-progress"
    case episodeProgress = "episode-progress"
    /// Recognized before anything writes them: repair deletes tombstones with
    /// an unknown scope, and that delete syncs, so a build must know a scope
    /// before any peer can write it.
    case playlist
    case playlistItem = "playlist-item"
}
