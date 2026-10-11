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

    init(episodeID: String, timestamp: TimeInterval, text: String) {
        self.episodeID = episodeID
        self.timestamp = timestamp
        self.text = text
    }
}
