import OpenCastCore

nonisolated enum PublisherChaptersResolution: Equatable, Sendable {
    /// Never empty.
    case chapters([EpisodeChapter])
    /// Fetched and decoded fine, with nothing usable in it.
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
