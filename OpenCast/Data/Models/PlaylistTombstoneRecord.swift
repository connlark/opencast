import Foundation
import SwiftData

/// A synced deletion marker for playlists. It is its own model rather than a
/// `SyncTombstoneRecord` scope because a build that predates playlists
/// deletes shared tombstones whose scope it does not know and syncs that
/// delete, while a record type that build has no model for stays invisible
/// to it.
///
/// With `episodeID == nil` it deletes the whole playlist whatever the
/// timestamps, since a playlist ID is minted per creation and never reused.
/// With an `episodeID` it deletes that episode's membership added at or
/// before `deletedAt`, so adding the episode again later survives.
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
