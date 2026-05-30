import SwiftUI

struct OpenCastRootRoutingModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var sheetDestination: SheetDestination?

    let pruneSelectedRoute: () -> Void
    let presentNowPlaying: () -> Void
    let dismissNowPlaying: () -> Void
    let openExternalURL: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appModel.library.activePodcastIDs) { _, _ in
                pruneSelectedRoute()
            }
            .onChange(of: appModel.library.visibleEpisodeIDs) { _, _ in
                pruneSelectedRoute()
            }
            .onChange(of: appModel.nowPlayingPresentationRequest) { _, _ in
                presentNowPlaying()
            }
            .onChange(of: appModel.onboardingPresentationRequest) { _, _ in
                sheetDestination = .onboarding
            }
            .onChange(of: appModel.playback.currentEpisode?.id.rawValue) { _, newEpisodeID in
                if newEpisodeID == nil {
                    dismissNowPlaying()
                }
            }
            .onOpenURL(perform: openExternalURL)
    }
}
