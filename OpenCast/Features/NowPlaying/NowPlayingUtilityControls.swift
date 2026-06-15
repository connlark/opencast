import SwiftUI

struct NowPlayingUtilityControls: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let rate: Float
    let sleepTimerText: String
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

    private var sleepTimerButton: some View {
        PlayerUtilityButton(
            title: "Sleep",
            value: sleepTimerText,
            systemImage: "moon.zzz",
            action: onShowSleepTimer
        )
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(sleepTimerText)
    }
}
