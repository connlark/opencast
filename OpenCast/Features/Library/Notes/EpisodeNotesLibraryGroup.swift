import Foundation

/// One episode's section in the Notes library.
struct EpisodeNotesLibraryGroup: Identifiable {
    let episodeID: String
    let podcastID: String
    let podcastTitle: String
    let episodeTitle: String
    let artworkURL: String?
    /// The episode is in the library or downloads, so the header can open it
    /// and a timestamp can play it.
    let isResolved: Bool
    let publishedAt: Date?
    /// The notes the search kept: the episode note first, then the
    /// timestamped notes in timeline order.
    let notes: [EpisodeNoteRecord]
    /// The latest creation or edit across all of the episode's notes, those
    /// the search hid included, so narrowing a search never reorders sections.
    let latestActivity: Date

    var id: String {
        episodeID
    }
}
