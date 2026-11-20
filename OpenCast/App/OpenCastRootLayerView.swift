import SwiftUI

struct OpenCastRootLayerView<Content: View>: View {
    @Environment(OpenCastAppModel.self) private var appModel
    /// Owned here so the tab root's content and the Now Playing overlay share one value.
    @State private var sceneLibraryLayouts = SceneLibraryLayouts()

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
        @ViewBuilder content: () -> Content
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

            // Built with the playback surface, not on each tap, so opening the
            // card never rebuilds its view graph.
            if appModel.hasNowPlayingPresentationContent {
                NowPlayingOverlayView(
                    onDismissed: onDismissNowPlaying,
                    onOpenEpisode: onOpenCurrentEpisode,
                    onOpenPodcast: onOpenCurrentPodcast,
                    onOpenPlaylist: onOpenCurrentPlaylist,
                    onStopPlayback: onStopPlayback
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

            #if DEBUG || OPENCAST_PERFORMANCE_PROBES
            if NowPlayingFramePacingProbe.shared.isEnabled {
                NowPlayingFramePacingStatusView()
                    .allowsHitTesting(false)
                FrameProbeMarkButton()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            #endif
        }
        .environment(sceneLibraryLayouts)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: SceneLibraryLayouts.divisionRegions(in: proxy), initial: true) { _, regions in
                        sceneLibraryLayouts.markFoldable(ifReported: regions)
                    }
            }
            .ignoresSafeArea()
        }
    }
}
