import Foundation
import SwiftData

@Model
final class EpisodeCacheRecord {
    var episodeID: String = ""
    var podcastID: String = ""
    var podcastTitle: String = ""
    var title: String = ""
    var summary: String?
    var showNotesHTML: String?
    var publishedAt: Date?
    var duration: Double?
    var audioURL: String?
    var artworkURL: String?
    var artworkPreviewVersion: Int?
    var artworkPreviewCanonicalURLKey: String?
    var artworkPreviewSourceHash: String?
    var artworkPreviewPixelWidth: Int?
    var artworkPreviewPixelHeight: Int?
    var artworkPreviewRGBData: Data?
    var guid: String?
    var cachedAt: Date = Date()

    init(
        episodeID: String,
        podcastID: String,
        podcastTitle: String,
        title: String,
        summary: String? = nil,
        showNotesHTML: String? = nil,
        publishedAt: Date? = nil,
        duration: Double? = nil,
        audioURL: String? = nil,
        artworkURL: String? = nil,
        guid: String? = nil,
        cachedAt: Date = Date()
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.podcastTitle = podcastTitle
        self.title = title
        self.summary = summary
        self.showNotesHTML = showNotesHTML
        self.publishedAt = publishedAt
        self.duration = duration
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.guid = guid
        self.cachedAt = cachedAt
    }
}
