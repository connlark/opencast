import Foundation
import OpenCastPlayback

struct SleepTimerOption: Identifiable {
    /// The sleep choices offered from Now Playing.
    static let canonical: [SleepTimerOption] = [
        SleepTimerOption(title: "Off", mode: .off),
        SleepTimerOption(title: "End of Episode", mode: .endOfEpisode),
        SleepTimerOption(title: "15 Minutes", mode: .duration(15 * 60)),
        SleepTimerOption(title: "30 Minutes", mode: .duration(30 * 60)),
        SleepTimerOption(title: "45 Minutes", mode: .duration(45 * 60)),
        SleepTimerOption(title: "1 Hour", mode: .duration(60 * 60))
    ]

    let title: String
    let mode: PlaybackSleepTimerMode

    var isEndOfEpisode: Bool {
        mode == .endOfEpisode
    }

    var id: String {
        title
    }
}
