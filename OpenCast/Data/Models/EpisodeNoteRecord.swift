import Foundation
import SwiftData

@Model
final class EpisodeNoteRecord {
    var noteID: String = UUID().uuidString
    var episodeID: String = ""
    var timestamp: TimeInterval = 0
    var isEpisodeWide: Bool = false
    var text: String = ""
    var createdAt: Date = Date()
    /// Display fallbacks: episode resolution reaches only subscribed shows and
    /// downloads, so a note on a show the listener later leaves renders from
    /// these. Notes saved before they existed are filled by
    /// `EpisodeNoteStore.backfillEpisodeInfo`.
    var podcastID: String = ""
    var podcastTitle: String = ""
    var episodeTitle: String = ""
    var artworkURL: String?
    /// Nil until the first edit.
    var updatedAt: Date?

    init(episodeID: String, timestamp: TimeInterval, text: String) {
        self.episodeID = episodeID
        self.timestamp = timestamp
        self.text = text
    }
}
