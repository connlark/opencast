import OpenCastCore

/// What this device knows about an episode's feed-declared chapters
/// document. Only a document that was read and held nothing usable lets
/// opencast generate chapters for an episode whose feed declares one; a
/// document never read, or one that failed, stays conservative.
nonisolated enum PublisherChaptersResolution: Equatable, Sendable {
    /// Never empty.
    case chapters([EpisodeChapter])
    /// The stored entry for this URL holds zero chapters: the document was
    /// fetched and decoded fine, with nothing usable in it.
    case documentEmpty
    /// No successful fetch yet and nothing matching cached.
    case unavailable

    init(_ entry: PublisherChaptersCacheEntry?) {
        guard let entry else {
            self = .unavailable
            return
        }
        self = entry.chapters.isEmpty ? .documentEmpty : .chapters(entry.chapters)
    }
}
