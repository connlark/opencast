import Foundation

/// Captured before presenting the editor, so playback or an episode change cannot
/// move the note while the listener is typing.
struct EpisodeNoteDraft: Identifiable {
    let id = UUID()
    let episodeID: String
    let episodeTitle: String
    let timestamp: TimeInterval
    var noteID: String? = nil
    var initialText = ""
    var isEpisodeWide = false
    var resumesPlaybackOnDismiss = false
}
