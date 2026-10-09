import SwiftUI

struct OpenCastRootLayerView<Content: View>: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let onDismissNowPlaying: () -> Void
    let onOpenCurrentEpisode: () -> Void
    let onOpenCurrentPodcast: () -> Void
    let onOpenCurrentPlaylist: () -> Void
    let onStopPlayback: () -> Void
    let content: Content

    init(
        onDismissNowPlaying: @escaping () -> Void,
        onOpenCurrentEpisode: @escaping () -> Void,
        onOpenCurrentPodcast: @escaping () -> Void,
        onOpenCurrentPlaylist: @escaping () -> Void,
        onStopPlayback: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onDismissNowPlaying = onDismissNowPlaying
        self.onOpenCurrentEpisode = onOpenCurrentEpisode
        self.onOpenCurrentPodcast = onOpenCurrentPodcast
        self.onOpenCurrentPlaylist = onOpenCurrentPlaylist
        self.onStopPlayback = onStopPlayback
        self.content = content()
    }

    var body: some View {
        let isNowPlayingPresented = appModel.isNowPlayingPresented

        ZStack {
            content
                .allowsHitTesting(!isNowPlayingPresented)
                .accessibilityHidden(isNowPlayingPresented)

            // Prepare the card with the playback surface instead of rebuilding
            // its view graph on every tap. Hidden content stops observing clocks
            // and progress; dismissal resets its transient interaction state.
            if appModel.hasNowPlayingPresentationContent {
                NowPlayingOverlayView(
                    isPresented: isNowPlayingPresented,
                    onDismissed: onDismissNowPlaying,
                    onOpenEpisode: onOpenCurrentEpisode,
                    onOpenPodcast: onOpenCurrentPodcast,
                    onOpenPlaylist: onOpenCurrentPlaylist,
                    onStopPlayback: onStopPlayback
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

            #if DEBUG || OPENCAST_PERFORMANCE_PROBES
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
