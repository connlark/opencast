import SwiftUI

struct OpenCastTabRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var isSearchPresented = false

    @Binding var selectedTab: AppSection
    @Binding var libraryNavigationPath: [AppRoute]
    @Binding var inboxNavigationPath: [AppRoute]
    @Binding var downloadsNavigationPath: [AppRoute]
    @Binding var searchNavigationPath: [AppRoute]
    let isNowPlayingPresented: Bool
    let onAdd: () -> Void
    let onPresentDataNukeConfirmation: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AppSection.library.title, systemImage: AppSection.library.systemImage, value: AppSection.library) {
                NavigationStack(path: $libraryNavigationPath) {
                    LibraryView(
                        onAdd: onAdd
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: { episodeID in
                            libraryNavigationPath.append(.episodeDetail(id: episodeID))
                        }
                    )
                }
            }

            Tab(AppSection.inbox.title, systemImage: AppSection.inbox.systemImage, value: AppSection.inbox) {
                NavigationStack(path: $inboxNavigationPath) {
                    InboxView(
                        onAdd: onAdd,
                        onOpenEpisode: { episodeID in
                            inboxNavigationPath.append(.episodeDetail(id: episodeID))
                        },
                        onOpenAdDetectionQueue: {
                            inboxNavigationPath.append(.adDetectionQueue)
                        }
                    )
                    .withOpenCastDestinations()
                }
            }

            Tab(
                AppSection.downloads.title,
                systemImage: AppSection.downloads.systemImage,
                value: AppSection.downloads
            ) {
                NavigationStack(path: $downloadsNavigationPath) {
                    DownloadsView(
                        onOpenEpisode: { episodeID in
                            downloadsNavigationPath.append(.episodeDetail(id: episodeID))
                        }
                    )
                    .withOpenCastDestinations()
                }
            }
            .badge(appModel.downloads.activeDownloadCount)

            Tab(AppSection.settings.title, systemImage: AppSection.settings.systemImage, value: AppSection.settings) {
                NavigationStack {
                    SettingsView(
                        onPresentDataNukeConfirmation: onPresentDataNukeConfirmation
                    )
                }
            }

            Tab(
                AppSection.search.title,
                systemImage: AppSection.search.systemImage,
                value: AppSection.search,
                role: .search
            ) {
                NavigationStack(path: $searchNavigationPath) {
                    SearchView(
                        directoryService: appModel.podcastDirectoryService,
                        isSearchPresented: $isSearchPresented,
                        onOpenEpisode: { episodeID in
                            searchNavigationPath.append(.episodeDetail(id: episodeID))
                        },
                        onOpenPodcast: { feedURL in
                            searchNavigationPath.append(.podcastDetail(feedURL: feedURL))
                        }
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: { episodeID in
                            searchNavigationPath.append(.episodeDetail(id: episodeID))
                        }
                    )
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(tabBarMinimizeBehavior)
        .openCastMiniPlayerTabAccessory(
            isEnabled: appModel.playback.currentEpisode != nil
        ) {
            MiniPlayerView(
                isNowPlayingPresented: isNowPlayingPresented,
                onExpand: onPresentNowPlaying
            )
        }
        .sensoryFeedback(.success, trigger: appModel.library.subscriptionAddedToken)
        .sensoryFeedback(.success, trigger: appModel.library.refreshCompletedToken)
        .onChange(of: selectedTab, initial: true) { _, selectedTab in
            isSearchPresented = selectedTab == .search
        }
    }

    private var tabBarMinimizeBehavior: TabBarMinimizeBehavior {
        selectedTab == .settings ? .never : .onScrollDown
    }
}
