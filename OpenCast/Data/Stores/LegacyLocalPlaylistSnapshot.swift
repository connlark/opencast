import Foundation

/// The playlists an earlier build kept in the device-local store, read as
/// plain values before the container opens.
nonisolated struct LegacyLocalPlaylistSnapshot: Equatable, Sendable {
    nonisolated struct Playlist: Equatable, Sendable {
        var playlistID: String
        var name: String
        var kindRawValue: String
        var ruleJSON: String?
        var hidesPlayed: Bool
        var tintKey: String?
        var originRawValue: String
        var createdAt: Date
        var updatedAt: Date
    }

    nonisolated struct Item: Equatable, Sendable {
        var itemID: String
        var playlistID: String
        var episodeID: String
        var podcastID: String
        var sortKey: String
        var addedAt: Date
        var updatedAt: Date
        var episodeTitle: String
        var podcastTitle: String
        var artworkURL: String?
        var audioURL: String?
        var duration: TimeInterval?
        var publishedAt: Date?
    }

    var playlists: [Playlist] = []
    var items: [Item] = []

    var isEmpty: Bool {
        playlists.isEmpty && items.isEmpty
    }
}
