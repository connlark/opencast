import SwiftUI

struct OpenCastRootLayerView<Content: View>: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let isNowPlayingPresented: Bool
    let onPresentNowPlaying: () -> Void
    let onDismissNowPlaying: () -> Void
    let onOpenCurrentEpisode: () -> Void
    let onOpenCurrentPodcast: () -> Void
    let content: () -> Content

    private static var miniPlayerHorizontalPadding: CGFloat { 20 }
    // Calibrated against iPhone 17 / iOS 26 floating-tab frames; do not derive casually.
    private static var miniPlayerBottomPadding: CGFloat { 57 }

    init(
        isNowPlayingPresented: Bool,
        onPresentNowPlaying: @escaping () -> Void,
        onDismissNowPlaying: @escaping () -> Void,
        onOpenCurrentEpisode: @escaping () -> Void,
        onOpenCurrentPodcast: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isNowPlayingPresented = isNowPlayingPresented
        self.onPresentNowPlaying = onPresentNowPlaying
        self.onDismissNowPlaying = onDismissNowPlaying
        self.onOpenCurrentEpisode = onOpenCurrentEpisode
        self.onOpenCurrentPodcast = onOpenCurrentPodcast
        self.content = content
    }

    var body: some View {
        ZStack {
            content()
                .allowsHitTesting(!isNowPlayingPresented)
                .accessibilityHidden(isNowPlayingPresented)

            Group {
                if showsCompactMiniPlayer {
                    MiniPlayerView(
                        isNowPlayingPresented: isNowPlayingPresented,
                        onExpand: onPresentNowPlaying
                    )
                    .padding(.horizontal, Self.miniPlayerHorizontalPadding)
                    .padding(.bottom, Self.miniPlayerBottomPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityHidden(isNowPlayingPresented)
                    .transition(miniPlayerTransition)
                    .zIndex(0.5)
                }
            }
            .animation(miniPlayerEntranceAnimation, value: isNowPlayingPresented)

            if appModel.playback.currentEpisode != nil || isNowPlayingPresented {
                NowPlayingOverlayView(
                    isPresented: isNowPlayingPresented,
                    onDismissed: onDismissNowPlaying,
                    onOpenEpisode: onOpenCurrentEpisode,
                    onOpenPodcast: onOpenCurrentPodcast
                )
                .allowsHitTesting(isNowPlayingPresented)
                .accessibilityHidden(!isNowPlayingPresented)
                .zIndex(1)
            }

            if appModel.exposesVoiceBoostDiagnosticsStatus,
               let voiceBoostDiagnostics = appModel.voiceBoostDiagnostics {
                VoiceBoostDiagnosticsStatusView(
                    diagnostics: voiceBoostDiagnostics,
                    playbackState: appModel.playback.state,
                    playbackPosition: appModel.playback.position,
                    hasEpisode: appModel.playback.currentEpisode != nil
                )
                .allowsHitTesting(false)
            }

            #if DEBUG
            if NowPlayingFramePacingProbe.shared.isEnabled {
                NowPlayingFramePacingStatusView()
                    .allowsHitTesting(false)
            }
            #endif
        }
    }

    private var showsCompactMiniPlayer: Bool {
        horizontalSizeClass != .regular
            && !isNowPlayingPresented
            && appModel.playback.currentEpisode != nil
    }

    private var miniPlayerTransition: AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity
            : .opacity
                .combined(with: .offset(x: 0, y: 44))
                .combined(with: .scale(scale: 0.985, anchor: .bottom))

        return .asymmetric(insertion: insertion, removal: .identity)
    }

    private var miniPlayerEntranceAnimation: Animation {
        .easeOut(duration: 0.18)
    }
}
