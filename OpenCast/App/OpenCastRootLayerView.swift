import SwiftUI

struct OpenCastRootLayerView<Content: View>: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let isNowPlayingPresented: Bool
    let onDismissNowPlaying: () -> Void
    let onOpenCurrentEpisode: () -> Void
    let onOpenCurrentPodcast: () -> Void
    let content: () -> Content

    init(
        isNowPlayingPresented: Bool,
        onDismissNowPlaying: @escaping () -> Void,
        onOpenCurrentEpisode: @escaping () -> Void,
        onOpenCurrentPodcast: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isNowPlayingPresented = isNowPlayingPresented
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

            // Mounted only while presented: the overlay animates itself in on
            // appear and calls onDismissed after its exit animation, so the
            // full Now Playing tree never idles behind the tab content
            // re-evaluating on every playback tick.
            if isNowPlayingPresented {
                NowPlayingOverlayView(
                    isPresented: isNowPlayingPresented,
                    onDismissed: onDismissNowPlaying,
                    onOpenEpisode: onOpenCurrentEpisode,
                    onOpenPodcast: onOpenCurrentPodcast
                )
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
                FrameProbeMarkButton()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            #endif
        }
    }
}
