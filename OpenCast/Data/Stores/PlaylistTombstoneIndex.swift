import Foundation

struct PlaylistTombstoneIndex {
    struct ItemKey: Hashable {
        let playlistID: String
        let episodeID: String
    }

    private(set) var deletedPlaylistIDs: Set<String> = []
    private(set) var latestItemClears: [ItemKey: Date] = [:]

    /// Malformed tombstones index nothing: an empty key would otherwise shadow every row whose key
    /// was never set.
    init(_ tombstones: [PlaylistTombstoneRecord]) {
        for tombstone in tombstones where !tombstone.playlistID.isEmpty {
            guard let episodeID = tombstone.episodeID else {
                deletedPlaylistIDs.insert(tombstone.playlistID)
                continue
            }
            guard !episodeID.isEmpty else { continue }
            let key = ItemKey(playlistID: tombstone.playlistID, episodeID: episodeID)
            latestItemClears[key] = max(latestItemClears[key] ?? tombstone.deletedAt, tombstone.deletedAt)
        }
    }

    /// A playlist ID is never reused, so a whole-playlist tombstone shadows
    /// the playlist whatever its timestamps.
    func shadowsPlaylist(_ playlistID: String) -> Bool {
        !playlistID.isEmpty && deletedPlaylistIDs.contains(playlistID)
    }

    /// Gated on `addedAt`, not `updatedAt`: a reorder after the removal must
    /// not resurrect the row, while adding the episode again must survive.
    func shadowsItem(playlistID: String, episodeID: String, addedAt: Date) -> Bool {
        if shadowsPlaylist(playlistID) {
            return true
        }
        guard !playlistID.isEmpty, !episodeID.isEmpty,
              let clearedAt = latestItemClears[ItemKey(playlistID: playlistID, episodeID: episodeID)]
        else {
            return false
        }
        return addedAt.timeIntervalSinceReferenceDate <= clearedAt.timeIntervalSinceReferenceDate
    }
}
