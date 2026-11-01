import Foundation
import SwiftData

/// Plays an episode from a tapped timestamp: scrubs the current episode, or
/// starts this one at that time without presenting Now Playing. A note or
/// show-notes timestamp carries no transcript hash to align against, unlike
/// a chapter, so a plain seek or a plain start is the best available answer.
enum EpisodeTimestampPlayback {
    static func seek(
        to seconds: TimeInterval,
        episode: EpisodeListItemSnapshot,
        appModel: OpenCastAppModel,
        modelContext: ModelContext
    ) throws {
        if appModel.playback.currentEpisode?.id.rawValue == episode.episodeID {
            appModel.playback.seek(to: seconds, intent: .scrub)
            if appModel.playback.state != .playing {
                appModel.playback.play()
            }
            return
        }

        try appModel.playEpisode(episode, at: seconds, presentsNowPlaying: false, modelContext: modelContext)
    }
}
