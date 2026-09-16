import Foundation
import SwiftData

/// Seeks playback to a cited transcript time from a Recap or Ask sheet:
/// scrubs the current episode, or starts this episode at the time without
/// presenting Now Playing. Errors surface through the app model's playback
/// error like every other play action.
enum TranscriptCitationSeeker {
    static func seek(
        to time: TimeInterval,
        episodeID: String,
        document: EpisodeTranscriptDocument?,
        appModel: OpenCastAppModel,
        modelContext: ModelContext
    ) {
        if appModel.playback.currentEpisode?.id.rawValue == episodeID {
            appModel.playback.seek(to: time, intent: .scrub)
            if appModel.playback.state != .playing {
                appModel.playback.play()
            }
            return
        }
        guard let document, let snapshot = appModel.episodeSnapshot(for: episodeID) else {
            appModel.lastPlaybackError = "This episode is no longer in the library."
            return
        }
        do {
            try appModel.playEpisode(
                snapshot,
                at: time,
                matchingSourceSHA256: document.sourceFileSHA256,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }
}
