import Foundation
import OpenCastPlayback

struct SleepTimerOption: Identifiable {
    /// The sleep choices offered from Now Playing: Off, End of Episode,
    /// then the listener's presets shortest first.
    static func options(presets: [SleepTimerPresetDuration]) -> [SleepTimerOption] {
        let presetOptions = Set(presets).sorted().map { preset in
            SleepTimerOption(title: preset.title, mode: .duration(preset.seconds))
        }
        return [
            SleepTimerOption(title: "Off", mode: .off),
            SleepTimerOption(title: "End of Episode", mode: .endOfEpisode)
        ] + presetOptions
    }

    let title: String
    let mode: PlaybackSleepTimerMode

    var isEndOfEpisode: Bool {
        mode == .endOfEpisode
    }

    var id: String {
        title
    }
}
