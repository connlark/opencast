import Foundation

/// One episode as Make a Playlist sees it, captured from the library once
/// per sheet so every index the model returns resolves against the same list.
nonisolated struct PlaylistOrganizerEpisode: Equatable, Sendable {
    /// Position in the show's newest-first episode list; 0 is the newest.
    var index: Int
    var episodeID: String
    var publishedAt: Date?
    var duration: TimeInterval?
    var title: String
    /// Plain text, already cleaned and cut to at most 200 characters.
    var snippet: String?
}
