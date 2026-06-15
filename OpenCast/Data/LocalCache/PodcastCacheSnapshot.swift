import Foundation

nonisolated struct PodcastCacheSnapshot: Identifiable, Equatable, Sendable {
    let feedURL: String
    let title: String
    let author: String?
    let summary: String?
    let websiteURL: String?
    let artworkURL: String?
    var artworkPreview: ArtworkPreview?
    let updatedAt: Date

    var id: String {
        feedURL
    }
}
