enum SyncTombstoneScope: String {
    case subscription
    case feedProgress = "feed-progress"
    case episodeProgress = "episode-progress"
    /// Reserved and never written: playlist deletes use
    /// `PlaylistTombstoneRecord`. Repair deletes tombstones with an unknown
    /// scope and that delete syncs, so these stay known in case a stray one
    /// ever reaches the store.
    case playlist
    case playlistItem = "playlist-item"
}
