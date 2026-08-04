import SwiftUI

/// The hero's glass action bar: stateful download, prominent Play, and the
/// one-tap Make Ad-Free pipeline entry.
struct EpisodeActionBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var glassNamespace
    @ScaledMetric(relativeTo: .body) private var sideButtonSize: CGFloat = 60
    @ScaledMetric(relativeTo: .body) private var playButtonSize: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var sideIconSize: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var playIconSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var completionBadgeSize: CGFloat = 20
    @State private var playFeedback = 0
    private let playIconOpticalOffset: CGFloat = 3

    let downloadRecord: EpisodeDownloadRecord?
    var downloadLiveProgress: DownloadByteProgress?
    let detectAdsState: EpisodeDetectAdsMenuState
    let showsPauseButton: Bool
    let onTogglePlayback: () -> Void
    let onDownload: () -> Void
    let onResumeDownload: () -> Void
    let onCancelDownload: () -> Void
    let onDeleteDownload: () -> Void
    let onMakeAdFree: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: glassSpacing) {
            HStack(spacing: controlSpacing) {
                EpisodeDownloadActionButton(
                    record: downloadRecord,
                    liveProgress: downloadLiveProgress,
                    glassNamespace: glassNamespace,
                    buttonSize: resolvedSideButtonSize,
                    iconSize: resolvedSideIconSize,
                    onDownload: onDownload,
                    onResume: onResumeDownload,
                    onCancel: onCancelDownload,
                    onDelete: onDeleteDownload
                )

                playButton

                makeAdFreeButton
            }
        }
        .overlay(alignment: .topTrailing) {
            if detectAdsState == .detected {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: resolvedCompletionBadgeSize, height: resolvedCompletionBadgeSize)
                    .background(.green, in: .circle)
                    .padding(.top, completionBadgeTopInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
    }

    private var playButton: some View {
        Button(action: togglePlayback) {
            Label {
                Text(showsPauseButton ? "Pause Episode" : "Play Episode")
            } icon: {
                Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                    .resizable()
                    .scaledToFit()
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: resolvedPlayIconSize, height: resolvedPlayIconSize)
                    .offset(x: showsPauseButton ? 0 : playIconOpticalOffset)
                    .animation(.easeOut(duration: 0.2), value: showsPauseButton)
            }
            .labelStyle(.iconOnly)
            .frame(width: resolvedPlayButtonSize, height: resolvedPlayButtonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
        .glassEffectID("episodeActions.play", in: glassNamespace)
        .accessibilityLabel(showsPauseButton ? "Pause Episode" : "Play Episode")
        .accessibilityInputLabels(["Play Episode", "Pause Episode"])
        .accessibilityIdentifier("Episode Playback Control")
    }

    private func togglePlayback() {
        onTogglePlayback()
        playFeedback += 1
    }

    private var makeAdFreeButton: some View {
        Button(action: onMakeAdFree) {
            Label {
                Text("Make Ad-Free")
            } icon: {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .frame(width: resolvedSideIconSize, height: resolvedSideIconSize)
            }
            .labelStyle(.iconOnly)
            .frame(width: resolvedSideButtonSize, height: resolvedSideButtonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(detectAdsState.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("episodeActions.makeAdFree", in: glassNamespace)
        .disabled(!detectAdsState.isEnabled)
        .accessibilityLabel("Make Ad-Free")
        .accessibilityValue(makeAdFreeAccessibilityValue)
    }

    private var makeAdFreeAccessibilityValue: String {
        switch detectAdsState {
        case .detect:
            ""
        case .detecting:
            "In progress"
        case .queued:
            "Queued"
        case .detected:
            "Ads detected"
        }
    }

    private var resolvedSideButtonSize: CGFloat {
        sideButtonSize.clamped(to: 44...(dynamicTypeSize.isAccessibilitySize ? 56 : 66))
    }

    private var resolvedPlayButtonSize: CGFloat {
        playButtonSize.clamped(to: 52...(dynamicTypeSize.isAccessibilitySize ? 68 : 84))
    }

    private var resolvedSideIconSize: CGFloat {
        sideIconSize.clamped(to: 20...(dynamicTypeSize.isAccessibilitySize ? 26 : 30))
    }

    private var resolvedPlayIconSize: CGFloat {
        playIconSize.clamped(to: 24...(dynamicTypeSize.isAccessibilitySize ? 30 : 36))
    }

    private var resolvedCompletionBadgeSize: CGFloat {
        completionBadgeSize.clamped(to: 18...(dynamicTypeSize.isAccessibilitySize ? 22 : 20))
    }

    private var completionBadgeTopInset: CGFloat {
        max((resolvedPlayButtonSize - resolvedSideButtonSize) / 2, 0)
    }

    private var controlSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 32
    }

    private var glassSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 18 : 28
    }
}

#Preview("Dark") {
    EpisodeActionBar(
        downloadRecord: nil,
        detectAdsState: .detect,
        showsPauseButton: false,
        onTogglePlayback: {}, onDownload: {}, onResumeDownload: {},
        onCancelDownload: {}, onDeleteDownload: {}, onMakeAdFree: {}
    )
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodeActionBar(
        downloadRecord: EpisodeDownloadRecord(
            episodeID: "preview",
            podcastID: "preview",
            sourceAudioURL: "https://example.com/a.mp3",
            state: .completed
        ),
        detectAdsState: .detected,
        showsPauseButton: true,
        onTogglePlayback: {}, onDownload: {}, onResumeDownload: {},
        onCancelDownload: {}, onDeleteDownload: {}, onMakeAdFree: {}
    )
    .padding()
    .preferredColorScheme(.light)
}

#Preview("AX5") {
    EpisodeActionBar(
        downloadRecord: nil,
        detectAdsState: .detect,
        showsPauseButton: false,
        onTogglePlayback: {}, onDownload: {}, onResumeDownload: {},
        onCancelDownload: {}, onDeleteDownload: {}, onMakeAdFree: {}
    )
    .padding()
    .dynamicTypeSize(.accessibility5)
}
