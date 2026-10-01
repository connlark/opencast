import Foundation
import SwiftData

/// One episode reference in a manual playlist. Device-local today but shaped
/// for CloudKit: an immutable `itemID` so duplicate repair has a stable
/// winner, logical dedupe on `(playlistID, episodeID)` in the store rather
/// than a constraint, and a `PlaylistSortKey` so a move rewrites one row.
@Model
final class PlaylistItemRecord {
    var itemID: String = ""
    var playlistID: String = ""
    var episodeID: String = ""
    var podcastID: String = ""
    var sortKey: String = ""
    var addedAt: Date = Date()
    var updatedAt: Date = Date()
    /// Display fallbacks: episode resolution reaches only subscribed shows and
    /// downloads, so an item from an unsubscribed show renders from these.
    var episodeTitle: String = ""
    var podcastTitle: String = ""
    var artworkURL: String?
    var audioURL: String?
    var duration: TimeInterval?
    var publishedAt: Date?
    /// Stable per-record identity so duplicate repair picks the same winner on
    /// every device once playlists sync (smallest UUID wins).
    var dedupeUUID: String = ""

    init(
        itemID: String = UUID().uuidString,
        playlistID: String,
        episodeID: String,
        podcastID: String,
        sortKey: String,
        addedAt: Date = .now,
        updatedAt: Date = .now,
        episodeTitle: String,
        podcastTitle: String,
        artworkURL: String? = nil,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil,
        dedupeUUID: String = UUID().uuidString
    ) {
        self.itemID = itemID
        self.playlistID = playlistID
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.sortKey = sortKey
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.artworkURL = artworkURL
        self.audioURL = audioURL
        self.duration = duration
        self.publishedAt = publishedAt
        self.dedupeUUID = dedupeUUID
    }
}
