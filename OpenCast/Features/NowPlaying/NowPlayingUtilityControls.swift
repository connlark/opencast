import SwiftUI

struct NowPlayingUtilityControls: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let rate: Float
    let onShowSpeed: () -> Void
    let onShowSleepTimer: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    playbackSpeedButton
                    AirPlayRoutePickerButton()
                    sleepTimerButton
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    playbackSpeedButton
                    AirPlayRoutePickerButton()
                    sleepTimerButton
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var playbackSpeedButton: some View {
        PlayerUtilityButton(
            title: "Speed",
            value: rate.formattedSpeed,
            systemImage: "speedometer",
            action: onShowSpeed
        )
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(rate.formattedSpeed)
    }

    @ViewBuilder
    private var sleepTimerButton: some View {
        if appModel.playback.sleepTimerMode != .off {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                sleepTimerButton(value: sleepTimerText(at: context.date))
            }
        } else {
            sleepTimerButton(value: "Off")
        }
    }

    private func sleepTimerButton(value: String) -> some View {
        PlayerUtilityButton(
            title: "Sleep",
            value: value,
            systemImage: "moon.zzz",
            action: onShowSleepTimer
        )
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(value)
    }

    private func sleepTimerText(at date: Date) -> String {
        guard let remaining = appModel.playback.sleepTimerRemaining(at: date) else {
            return appModel.playback.sleepTimerMode == .endOfEpisode ? "End of Episode" : "Off"
        }

        return remaining > 0 ? "-\(remaining.formattedPlaybackDuration)" : "Off"
    }
}
