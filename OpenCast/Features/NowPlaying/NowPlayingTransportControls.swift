import SwiftUI

struct NowPlayingTransportControls: View {
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
    @ScaledMetric(relativeTo: .body) private var playIconSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var playIconOpticalOffset: CGFloat = 4

    var body: some View {
        GlassEffectContainer(spacing: 34) {
            HStack(spacing: 42) {
                Button(action: onSkipBackward) {
                    Label(skipBackwardLabel, systemImage: skipBackwardSystemImage)
                        .font(.largeTitle)
                        .labelStyle(.iconOnly)
                        .frame(width: skipButtonSize, height: skipButtonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("transport.skipBackward", in: glassNamespace)
                .accessibilityLabel(skipBackwardLabel)

                Button(action: onTogglePlayPause) {
                    Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                        .resizable()
                        .scaledToFit()
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: playIconSize, height: playIconSize)
                        .offset(x: showsPauseButton ? 0 : playIconOpticalOffset)
                        .frame(width: playButtonSize, height: playButtonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                .glassEffectID("transport.playPause", in: glassNamespace)
                .accessibilityLabel(showsPauseButton ? "Pause" : "Play")
                .accessibilityValue(playbackStateText)

                Button(action: onSkipForward) {
                    Label(skipForwardLabel, systemImage: skipForwardSystemImage)
                        .font(.largeTitle)
                        .labelStyle(.iconOnly)
                        .frame(width: skipButtonSize, height: skipButtonSize)
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

extension NowPlayingTransportControls: Equatable {
    static func == (lhs: NowPlayingTransportControls, rhs: NowPlayingTransportControls) -> Bool {
        lhs.skipBackwardInterval == rhs.skipBackwardInterval
            && lhs.skipForwardInterval == rhs.skipForwardInterval
            && lhs.showsPauseButton == rhs.showsPauseButton
            && lhs.playbackStateText == rhs.playbackStateText
    }
}
