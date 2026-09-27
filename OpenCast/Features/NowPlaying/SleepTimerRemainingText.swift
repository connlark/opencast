import Foundation
import OpenCastPlayback

/// The sleep timer's one-line state, shared by the Sleep utility button and
/// the sheet so the two surfaces cannot drift.
enum SleepTimerRemainingText {
    static func text(for playback: AVFoundationPlaybackController, at date: Date) -> String {
        text(mode: playback.sleepTimerMode, remaining: playback.sleepTimerRemaining(at: date))
    }

    static func text(mode: PlaybackSleepTimerMode, remaining: TimeInterval?) -> String {
        guard let remaining else {
            return mode == .endOfEpisode ? "End of Episode" : "Off"
        }

        return remaining > 0 ? "-\(remaining.formattedPlaybackDuration)" : "Off"
    }
}
