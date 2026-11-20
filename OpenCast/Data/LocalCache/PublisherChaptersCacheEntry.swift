import Foundation
import OpenCastCore

nonisolated struct PublisherChaptersCacheEntry: Equatable, Sendable {
    /// A mismatch with the row's current `chapters_url` is a cache miss.
    var sourceURL: String
    var chapters: [EpisodeChapter]
    var fetchedAt: Date
}
