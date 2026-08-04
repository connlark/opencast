import SwiftUI

struct OpenCastTabRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var isSearchPresented = false

    @Binding var selectedTab: AppSection
    @Binding var navigationPaths: AppNavigationPaths
    let isNowPlayingPresented: Bool
    let onAdd: () -> Void
    let onPresentDataNukeConfirmation: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AppSection.library.title, systemImage: AppSection.library.systemImage, value: AppSection.library) {
                NavigationStack(path: $navigationPaths[.library]) {
                    LibraryView(
                        onAdd: onAdd
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .library)
                    )
                }
            }

            Tab(AppSection.inbox.title, systemImage: AppSection.inbox.systemImage, value: AppSection.inbox) {
                NavigationStack(path: $navigationPaths[.inbox]) {
                    InboxView(
                        onAdd: onAdd,
                        onOpenEpisode: openEpisode(on: .inbox),
                        onOpenAdDetectionQueue: {
                            navigationPaths[.inbox].append(.adDetectionQueue)
                        }
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .inbox)
                    )
                }
            }

            Tab(
                AppSection.downloads.title,
                systemImage: AppSection.downloads.systemImage,
                value: AppSection.downloads
            ) {
                NavigationStack(path: $navigationPaths[.downloads]) {
                    DownloadsView(
                        onOpenEpisode: openEpisode(on: .downloads)
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .downloads)
                    )
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
                NavigationStack(path: $navigationPaths[.search]) {
                    SearchView(
                        directoryService: appModel.podcastDirectoryService,
                        isSearchPresented: $isSearchPresented,
                        onOpenEpisode: openEpisode(on: .search),
                        onOpenPodcast: { feedURL in
                            navigationPaths[.search].append(.podcastDetail(feedURL: feedURL))
                        }
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .search)
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
        .focusedSceneValue(\.openCastCommandActions, commandActions)
    }

    private func openEpisode(on section: AppSection) -> (String) -> Void {
        { episodeID in
            navigationPaths[section].append(.episodeDetail(id: episodeID))
        }
    }

    private var commandActions: OpenCastCommandActions {
        OpenCastCommandActions.make(
            playback: appModel.playback,
            focusSearch: {
                selectedTab = .search
                isSearchPresented = true
            }
        )
    }

    private var tabBarMinimizeBehavior: TabBarMinimizeBehavior {
        selectedTab == .settings ? .never : .onScrollDown
    }
}
