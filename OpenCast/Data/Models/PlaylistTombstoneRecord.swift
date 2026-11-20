import Foundation
import SwiftData

/// Its own model, not a `SyncTombstoneRecord` scope: a build without playlists deletes
/// shared tombstones of an unknown scope and syncs that delete, but cannot see a model it
/// lacks.
@Model
final class PlaylistTombstoneRecord {
    var playlistID: String = ""
    var episodeID: String?
    var deletedAt: Date = Date()

    init(playlistID: String, episodeID: String? = nil, deletedAt: Date = .now) {
        self.playlistID = playlistID
        self.episodeID = episodeID
        self.deletedAt = deletedAt
    }
}
