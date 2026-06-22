import SwiftUI

struct OpenCastTabRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var selectedTab: AppSection
    @Binding var libraryNavigationPath: [AppRoute]
    @Binding var inboxNavigationPath: [AppRoute]
    let onAdd: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDataNukeConfirmation: () -> Void

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AppSection.inbox.title, systemImage: AppSection.inbox.systemImage, value: AppSection.inbox) {
                NavigationStack(path: $inboxNavigationPath) {
                    InboxView(
                        onAdd: onAdd,
                        onOpenSettings: onOpenSettings,
                        onOpenEpisode: { episodeID in
                            inboxNavigationPath.append(.episodeDetail(id: episodeID))
                        }
                    )
                    .withOpenCastDestinations()
                }
            }

            Tab(AppSection.library.title, systemImage: AppSection.library.systemImage, value: AppSection.library) {
                NavigationStack(path: $libraryNavigationPath) {
                    LibraryView(
                        usesNavigationLinks: true,
                        onAdd: onAdd,
                        onOpenPodcast: { _ in }
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: { episodeID in
                            libraryNavigationPath.append(.episodeDetail(id: episodeID))
                        }
                    )
                }
            }

            Tab(AppSection.settings.title, systemImage: AppSection.settings.systemImage, value: AppSection.settings) {
                NavigationStack {
                    SettingsView(
                        onPresentDataNukeConfirmation: onPresentDataNukeConfirmation
                    )
                }
            }
        }
        .tabBarMinimizeBehavior(tabBarMinimizeBehavior)
    }

    private var tabBarMinimizeBehavior: TabBarMinimizeBehavior {
        appModel.playback.currentEpisode == nil ? .onScrollDown : .never
    }
}
