import SwiftUI

struct NowPlayingUtilityControls: View {
    static let spacing = 12.0

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var circleDiameter = PlayerUtilityCircleChrome.defaultDiameter

    let rate: Float
    /// The width the controls are laid out in; a single row that would not
    /// fit falls back to the grid instead of overflowing the screen edges.
    let availableWidth: Double
    let onShowSpeed: () -> Void
    let onShowSleepTimer: () -> Void
    let onShowUpNext: () -> Void
    var onAddNote: (() -> Void)? = nil

    var body: some View {
        GlassEffectContainer(spacing: Self.spacing) {
            if usesGrid {
                Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                    GridRow {
                        playbackSpeedButton
                        AirPlayRoutePickerButton()
                    }
                    GridRow {
                        sleepTimerButton
                        upNextButton
                    }
                    if let onAddNote {
                        GridRow {
                            addNoteButton(action: onAddNote)
                                .gridCellColumns(2)
                        }
                    }
                }
            } else {
                HStack(alignment: .center, spacing: Self.spacing) {
                    playbackSpeedButton
                    AirPlayRoutePickerButton()
                    sleepTimerButton
                    upNextButton
                    if let onAddNote {
                        addNoteButton(action: onAddNote)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var usesGrid: Bool {
        dynamicTypeSize.isAccessibilitySize
            || Self.rowWidth(circleCount: onAddNote == nil ? 4 : 5, scaledDiameter: circleDiameter) > availableWidth
    }

    static func rowWidth(circleCount: Int, scaledDiameter: Double) -> Double {
        let count = Double(circleCount)
        return count * PlayerUtilityCircleChrome.diameter(scaled: scaledDiameter) + (count - 1) * spacing
    }

    private func addNoteButton(action: @escaping () -> Void) -> some View {
        PlayerUtilityCircleButton(title: "Add Note", systemImage: "square.and.pencil", action: action)
            .accessibilityIdentifier("Add Timestamped Note")
    }

    private var playbackSpeedButton: some View {
        PlayerUtilitySpeedButton(rate: rate, action: onShowSpeed)
    }

    private var sleepTimerButton: some View {
        TimelineView(.animation(
            minimumInterval: 1,
            paused: !appModel.isNowPlayingPresented || scenePhase != .active || appModel.playback.sleepTimerMode == .off
        )) { context in
            sleepTimerButton(
                value: sleepTimerText(at: context.date),
                progress: sleepTimerProgress(at: context.date)
            )
        }
    }

    private func sleepTimerButton(value: String, progress: Double?) -> some View {
        let isActive = appModel.playback.sleepTimerMode != .off
        return PlayerUtilityCircleButton(
            title: "Sleep",
            systemImage: isActive ? "moon.zzz.fill" : "moon.zzz",
            isActive: isActive,
            progress: progress,
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
        SleepTimerRemainingText.text(for: appModel.playback, at: date)
    }

    private func sleepTimerProgress(at date: Date) -> Double? {
        guard case .duration(let duration) = appModel.playback.sleepTimerMode,
              duration > 0,
              let remaining = appModel.playback.sleepTimerRemaining(at: date) else {
            return nil
        }

        return min(max(remaining / duration, 0), 1)
    }

    private func queueAccessibilityValue(count: Int) -> Text {
        if let source = appModel.currentPlaylistSource {
            let remaining = appModel.remainingQueuedCount(forPlaylist: source.playlistID)
            if remaining >= 1 {
                return Text(PlaylistPlaybackSourceText.utilityValue(name: source.name, remainingCount: remaining))
            }
        }
        return count == 0
            ? Text("Empty")
            : Text("^[\(count) episode](inflect: true) queued")
    }
}
