import SwiftUI

struct OpenCastAdaptiveRootContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var selectedTab: AppSection
    @Binding var selectedSection: AppSection?
    @Binding var selectedRoute: AppRoute?
    @Binding var libraryNavigationPath: [AppRoute]
    @Binding var inboxNavigationPath: [AppRoute]
    let isNowPlayingPresented: Bool
    let onAdd: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        if horizontalSizeClass == .regular {
            OpenCastSplitRootView(
                selectedSection: $selectedSection,
                selectedRoute: $selectedRoute,
                isNowPlayingPresented: isNowPlayingPresented,
                onAdd: onAdd,
                onPresentNowPlaying: onPresentNowPlaying
            )
        } else {
            OpenCastTabRootView(
                selectedTab: $selectedTab,
                libraryNavigationPath: $libraryNavigationPath,
                inboxNavigationPath: $inboxNavigationPath,
                isNowPlayingPresented: isNowPlayingPresented,
                onAdd: onAdd,
                onPresentNowPlaying: onPresentNowPlaying
            )
        }
    }
}
