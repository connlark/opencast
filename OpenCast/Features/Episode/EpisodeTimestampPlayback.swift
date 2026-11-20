import Foundation
import SwiftData

/// A note or show-notes timestamp, unlike a chapter, has no transcript hash to align against,
/// so a plain seek or start is the best available answer.
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
