import SwiftUI

struct NowPlayingTransportControls: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let skipBackwardInterval: TimeInterval
    let skipForwardInterval: TimeInterval
    let showsPauseButton: Bool
    let playbackStateText: String
    let onSkipBackward: () -> Void
    let onTogglePlayPause: () -> Void
    let onSkipForward: () -> Void

    @Namespace private var glassNamespace
    @ScaledMetric(relativeTo: .body) private var skipButtonSize: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var playButtonSize: CGFloat = 90
    @ScaledMetric(relativeTo: .body) private var skipIconSize: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var playIconSize: CGFloat = 44
    private let playIconOpticalOffset: CGFloat = 4

    var body: some View {
        GlassEffectContainer(spacing: glassSpacing) {
            HStack(spacing: controlSpacing) {
                Button(action: onSkipBackward) {
                    Label {
                        Text(skipBackwardLabel)
                    } icon: {
                        Image(systemName: skipBackwardSystemImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: resolvedSkipIconSize, height: resolvedSkipIconSize)
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: resolvedSkipButtonSize, height: resolvedSkipButtonSize)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("transport.skipBackward", in: glassNamespace)
                .accessibilityLabel(skipBackwardLabel)

                Button(action: onTogglePlayPause) {
                    Label {
                        Text(showsPauseButton ? "Pause" : "Play")
                    } icon: {
                        Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                            .resizable()
                            .scaledToFit()
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: resolvedPlayIconSize, height: resolvedPlayIconSize)
                            .offset(x: showsPauseButton ? 0 : playIconOpticalOffset)
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: resolvedPlayButtonSize, height: resolvedPlayButtonSize)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                .glassEffectID("transport.playPause", in: glassNamespace)
                .accessibilityLabel(showsPauseButton ? "Pause" : "Play")
                .accessibilityValue(playbackStateText)

                Button(action: onSkipForward) {
                    Label {
                        Text(skipForwardLabel)
                    } icon: {
                        Image(systemName: skipForwardSystemImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: resolvedSkipIconSize, height: resolvedSkipIconSize)
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: resolvedSkipButtonSize, height: resolvedSkipButtonSize)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("transport.skipForward", in: glassNamespace)
                .accessibilityLabel(skipForwardLabel)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }

    private var skipBackwardSeconds: Int {
        Int(skipBackwardInterval.rounded())
    }

    private var skipForwardSeconds: Int {
        Int(skipForwardInterval.rounded())
    }

    private var resolvedSkipButtonSize: CGFloat {
        skipButtonSize.clamped(to: 44...maxSkipButtonSize)
    }

    private var resolvedPlayButtonSize: CGFloat {
        playButtonSize.clamped(to: 52...maxPlayButtonSize)
    }

    private var resolvedSkipIconSize: CGFloat {
        skipIconSize.clamped(to: 24...maxSkipIconSize)
    }

    private var resolvedPlayIconSize: CGFloat {
        playIconSize.clamped(to: 26...maxPlayIconSize)
    }

    private var maxSkipButtonSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 62 : 76
    }

    private var maxPlayButtonSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 74 : 96
    }

    private var maxSkipIconSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 28 : 38
    }

    private var maxPlayIconSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 34 : 46
    }

    private var controlSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 24 : 42
    }

    private var glassSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 22 : 34
    }

    private var skipBackwardLabel: String {
        "Skip Back \(skipBackwardSeconds) Seconds"
    }

    private var skipForwardLabel: String {
        "Skip Forward \(skipForwardSeconds) Seconds"
    }

    private var skipBackwardSystemImage: String {
        "gobackward.\(skipBackwardSeconds)"
    }

    private var skipForwardSystemImage: String {
        "goforward.\(skipForwardSeconds)"
    }
}
