import SwiftUI

struct OpenCastRootRoutingModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var sheetDestination: SheetDestination?

    let pruneNavigationPaths: () -> Void
    let presentNowPlaying: () -> Void
    let dismissNowPlaying: () -> Void
    let openExternalURL: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appModel.library.activePodcastIDs) { _, _ in
                pruneNavigationPaths()
            }
            .onChange(of: appModel.library.visibleEpisodeIDs) { _, _ in
                pruneNavigationPaths()
            }
            .onChange(of: appModel.nowPlayingPresentationRequest) { _, _ in
                presentNowPlaying()
            }
            .onChange(of: appModel.onboardingPresentationRequest) { _, _ in
                sheetDestination = .onboarding
            }
            .onChange(of: appModel.hasNowPlayingPresentationContent, initial: true) { _, hasContent in
                if !hasContent {
                    dismissNowPlaying()
                }
            }
            .onOpenURL(perform: openExternalURL)
    }
}
