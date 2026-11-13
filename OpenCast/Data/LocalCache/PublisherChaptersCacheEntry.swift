import Foundation
import OpenCastCore

/// Decoded feed-declared chapters cached on the episode row beside its
/// `chapters_url`.
nonisolated struct PublisherChaptersCacheEntry: Equatable, Sendable {
    /// The `chapters_url` the document was fetched from; a mismatch with the row's current URL is a miss.
    var sourceURL: String
    var chapters: [EpisodeChapter]
    var fetchedAt: Date
}
