import Foundation

nonisolated struct PlaylistItem: Identifiable, Equatable, Sendable {
    let itemID: String
    let playlistID: String
    let episodeID: String
    let podcastID: String
    var sortKey: String
    let addedAt: Date
    var updatedAt: Date
    let episodeTitle: String
    let podcastTitle: String
    let artworkURL: String?
    let audioURL: String?
    let duration: TimeInterval?
    let publishedAt: Date?

    var id: String {
        itemID
    }
}
