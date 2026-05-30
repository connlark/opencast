import Foundation
import SwiftData

@Model
final class PodcastCacheRecord {
    var feedURL: String = ""
    var title: String = ""
    var author: String?
    var summary: String?
    var websiteURL: String?
    var artworkURL: String?
    var updatedAt: Date = Date()

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        websiteURL: String? = nil,
        artworkURL: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.websiteURL = websiteURL
        self.artworkURL = artworkURL
        self.updatedAt = updatedAt
    }
}
