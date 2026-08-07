import SwiftUI

struct NowPlayingUtilityControls: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let rate: Float
    let onShowSpeed: () -> Void
    let onShowSleepTimer: () -> Void
    let onShowUpNext: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        playbackSpeedButton
                        AirPlayRoutePickerButton()
                    }
                    GridRow {
                        sleepTimerButton
                        upNextButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    playbackSpeedButton
                    AirPlayRoutePickerButton()
                    sleepTimerButton
                    upNextButton
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var playbackSpeedButton: some View {
        PlayerUtilitySpeedButton(rate: rate, action: onShowSpeed)
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
        let isActive = appModel.playback.sleepTimerMode != .off
        return PlayerUtilityCircleButton(
            title: "Sleep",
            systemImage: isActive ? "moon.zzz.fill" : "moon.zzz",
            isActive: isActive,
            replacesSymbol: true,
            action: onShowSleepTimer
        )
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(value)
    }

    private var upNextButton: some View {
        let count = appModel.upNextQueue.items.count
        return PlayerUtilityCircleButton(
            title: "Up Next",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            isActive: count > 0,
            action: onShowUpNext
        )
        .accessibilityValue(queueAccessibilityValue(count: count))
    }

    private func sleepTimerText(at date: Date) -> String {
        guard let remaining = appModel.playback.sleepTimerRemaining(at: date) else {
            return appModel.playback.sleepTimerMode == .endOfEpisode ? "End of Episode" : "Off"
        }

        return remaining > 0 ? "-\(remaining.formattedPlaybackDuration)" : "Off"
    }

    private func queueAccessibilityValue(count: Int) -> Text {
        count == 0
            ? Text("Empty")
            : Text("^[\(count) episode](inflect: true) queued")
    }
}
