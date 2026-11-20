enum SyncTombstoneScope: String {
    case subscription
    case feedProgress = "feed-progress"
    case episodeProgress = "episode-progress"
    /// Never written, but kept known: repair deletes a tombstone of an unknown scope and that
    /// delete syncs.
    case playlist
    case playlistItem = "playlist-item"
}
