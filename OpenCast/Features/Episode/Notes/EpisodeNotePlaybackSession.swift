import Foundation
import OpenCastPlayback

/// Owns the pause requested by the note editor, independently of the sheet
/// binding (which SwiftUI clears before delivering onDismiss).
struct EpisodeNotePlaybackSession {
    let draft: EpisodeNoteDraft
    let playbackIntentRevision: UInt64

    init(episodeID: String, title: String, timestamp: TimeInterval, state: PlaybackState, pause: () -> Void, playbackIntentRevision: () -> UInt64) {
        let shouldPause = state.showsPauseButton
        draft = EpisodeNoteDraft(
            episodeID: episodeID,
            episodeTitle: title,
            timestamp: timestamp,
            resumesPlaybackOnDismiss: shouldPause
        )
        if shouldPause { pause() }
        // Capture after our own pause advances the revision.
        self.playbackIntentRevision = playbackIntentRevision()
    }

    func finish(currentEpisodeID: String?, state: PlaybackState, playbackIntentRevision: UInt64, play: () -> Void) {
        guard draft.resumesPlaybackOnDismiss,
              currentEpisodeID == draft.episodeID,
              playbackIntentRevision == self.playbackIntentRevision,
              state == .paused else { return }
        play()
    }
}
