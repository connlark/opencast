import Foundation

/// Captured before presenting the editor, so playback or an episode change cannot
/// move the note while the listener is typing.
struct EpisodeNoteDraft: Identifiable {
    let id = UUID()
    let episodeID: String
    var podcastID = ""
    var podcastTitle = ""
    let episodeTitle: String
    var artworkURL: String? = nil
    let timestamp: TimeInterval
    var noteID: String? = nil
    var initialText = ""
    var isEpisodeWide = false
    var resumesPlaybackOnDismiss = false

    /// A new note at `timestamp` that carries the episode's display details.
    static func timestamped(
        episode: EpisodeListItemSnapshot,
        timestamp: TimeInterval,
        resumesPlaybackOnDismiss: Bool = false
    ) -> EpisodeNoteDraft {
        EpisodeNoteDraft(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            podcastTitle: episode.podcastTitle,
            episodeTitle: episode.title,
            artworkURL: episode.artworkURL,
            timestamp: timestamp,
            resumesPlaybackOnDismiss: resumesPlaybackOnDismiss
        )
    }

    /// A whole-episode draft that edits `existing` when the episode already has one.
    static func wholeEpisode(episode: EpisodeListItemSnapshot, existing: EpisodeNoteRecord?) -> EpisodeNoteDraft {
        EpisodeNoteDraft(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            podcastTitle: episode.podcastTitle,
            episodeTitle: episode.title,
            artworkURL: episode.artworkURL,
            timestamp: 0,
            noteID: existing?.noteID,
            initialText: existing?.text ?? "",
            isEpisodeWide: true
        )
    }

    /// Edits `note`, keeping its stored details and filling only the empty
    /// ones from `episode`, which is nil once the episode no longer resolves.
    static func editing(_ note: EpisodeNoteRecord, episode: EpisodeListItemSnapshot?) -> EpisodeNoteDraft {
        EpisodeNoteDraft(
            episodeID: note.episodeID,
            podcastID: stored(note.podcastID, else: episode?.podcastID),
            podcastTitle: stored(note.podcastTitle, else: episode?.podcastTitle),
            episodeTitle: stored(note.episodeTitle, else: episode?.title),
            artworkURL: note.artworkURL.flatMap { $0.isEmpty ? nil : $0 } ?? episode?.artworkURL,
            timestamp: note.timestamp,
            noteID: note.noteID,
            initialText: note.text,
            isEpisodeWide: note.isEpisodeWide
        )
    }

    private static func stored(_ value: String, else fallback: String?) -> String {
        value.isEmpty ? fallback ?? "" : value
    }
}
