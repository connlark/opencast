import SwiftUI

struct NowPlayingTransportControls: View {
    /// The play button before Dynamic Type scales it (relative to body).
    nonisolated static let playButtonBaseDiameter = 90.0

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `resolvedPlayButtonDiameter(scaled:isAccessibilitySize:)`, computed
    /// once by the card so the utility circles share it.
    let playButtonDiameter: Double
    let skipBackwardInterval: TimeInterval
    let skipForwardInterval: TimeInterval
    let showsPauseButton: Bool
    let showsLoadingIndicator: Bool
    let playbackStateText: String
    let onSkipBackward: () -> Void
    let onTogglePlayPause: () -> Void
    let onSkipForward: () -> Void

    @Namespace private var glassNamespace
    @ScaledMetric(relativeTo: .body) private var skipButtonSize: CGFloat = 72
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
                        Group {
                            if showsLoadingIndicator {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .contentTransition(.symbolEffect(.replace))
                                    .offset(x: showsPauseButton ? 0 : playIconOpticalOffset)
                            }
                        }
                        .frame(width: resolvedPlayIconSize, height: resolvedPlayIconSize)
                        .animation(.easeOut(duration: 0.2), value: showsLoadingIndicator)
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: playButtonDiameter, height: playButtonDiameter)
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

    /// The scaled play button under its maxima: 96 pt, or 74 pt at
    /// accessibility sizes, where the transport has to share the card.
    nonisolated static func resolvedPlayButtonDiameter(scaled: Double, isAccessibilitySize: Bool) -> Double {
        scaled.clamped(to: 52...(isAccessibilitySize ? 74 : 96))
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

    private var resolvedSkipIconSize: CGFloat {
        skipIconSize.clamped(to: 24...maxSkipIconSize)
    }

    private var resolvedPlayIconSize: CGFloat {
        playIconSize.clamped(to: 26...maxPlayIconSize)
    }

    private var maxSkipButtonSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 62 : 76
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
