import SwiftUI

struct NowPlayingUtilityControls: View {
    let rate: Float
    let sleepTimerText: String
    let onShowSpeed: () -> Void
    let onShowSleepTimer: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                PlayerUtilityButton(
                    title: "Speed",
                    value: rate.formattedSpeed,
                    systemImage: "speedometer",
                    action: onShowSpeed
                )
                .accessibilityLabel("Playback Speed")
                .accessibilityValue(rate.formattedSpeed)

                AirPlayRoutePickerButton()

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
        .foregroundStyle(.primary)
    }
}

extension NowPlayingUtilityControls: Equatable {
    static func == (lhs: NowPlayingUtilityControls, rhs: NowPlayingUtilityControls) -> Bool {
        lhs.rate == rhs.rate
            && lhs.sleepTimerText == rhs.sleepTimerText
    }
}
