import SwiftUI

struct OpenCastAdaptiveRootContentView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var selectedTab: AppSection
    @Binding var selectedSection: AppSection?
    @Binding var selectedRoute: AppRoute?
    @Binding var libraryNavigationPath: [AppRoute]
    @Binding var inboxNavigationPath: [AppRoute]
    let isNowPlayingPresented: Bool
    let onAdd: () -> Void
    let onPresentDataNukeConfirmation: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                OpenCastSplitRootView(
                    selectedSection: $selectedSection,
                    selectedRoute: $selectedRoute,
                    isNowPlayingPresented: isNowPlayingPresented,
                    onAdd: onAdd,
                    onPresentDataNukeConfirmation: onPresentDataNukeConfirmation,
                    onPresentNowPlaying: onPresentNowPlaying
                )
            } else {
                OpenCastTabRootView(
                    selectedTab: $selectedTab,
                    libraryNavigationPath: $libraryNavigationPath,
                    inboxNavigationPath: $inboxNavigationPath,
                    onAdd: onAdd,
                    onPresentDataNukeConfirmation: onPresentDataNukeConfirmation
                )
            }
        }
        .sensoryFeedback(.success, trigger: appModel.library.subscriptionAddedToken)
        .sensoryFeedback(.success, trigger: appModel.library.refreshCompletedToken)
    }
}
