import SwiftUI

struct OpenCastTabRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isSearchPresented = false
    @State private var showsPlaylistsTab = false

    @Binding var selectedTab: AppSection
    @Binding var navigationPaths: AppNavigationPaths
    let isNowPlayingPresented: Bool
    let onAdd: () -> Void
    let onOpenUpNext: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AppSection.library.title, systemImage: AppSection.library.systemImage, value: AppSection.library) {
                NavigationStack(path: $navigationPaths[.library]) {
                    LibraryView(
                        onAdd: onAdd,
                        onOpenUpNext: onOpenUpNext,
                        onOpenPlaylist: openPlaylist(on: .library)
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .library),
                        onOpenPlaylist: openPlaylist(on: .library)
                    )
                }
            }

            // `defaultVisibility(.hidden, for: .tabBar)` never leaves the compact
            // bar on iOS 27 (six tabs fold Settings and Search into More), so the
            // tab exists only in regular width; `updatePlaylistsTab` explains
            // why that switch is deferred.
            if showsPlaylistsTab {
                Tab(
                    AppSection.playlists.title,
                    systemImage: AppSection.playlists.systemImage,
                    value: AppSection.playlists
                ) {
                    NavigationStack(path: $navigationPaths[.playlists]) {
                        PlaylistsView(onOpenPlaylist: openPlaylist(on: .playlists))
                            .withOpenCastDestinations(
                                onOpenEpisode: openEpisode(on: .playlists),
                                onOpenPlaylist: openPlaylist(on: .playlists)
                            )
                    }
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
                NavigationStack(path: $navigationPaths[.settings]) {
                    SettingsView()
                        .withOpenCastDestinations()
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
                        directoryResolver: appModel.podcastDirectoryResolver,
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
        .tabViewBottomAccessory(isEnabled: showsTabAccessory) {
            tabAccessory
        }
        .sensoryFeedback(.success, trigger: appModel.library.subscriptionAddedToken)
        .sensoryFeedback(trigger: appModel.library.refreshCompletedToken) { _, _ in
            appModel.library.lastRefreshWasOffline ? .warning : .success
        }
        .onChange(of: selectedTab, initial: true) { _, selectedTab in
            isSearchPresented = selectedTab == .search
            leavePlaylistsTabIfCompact()
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            updatePlaylistsTab(isRegularWidth: sizeClass == .regular)
        }
        .focusedSceneValue(\.openCastCommandActions, commandActions)
    }

    /// A size-class change reaches SwiftUI inside UIKit's trait transition,
    /// and rebuilding the tab set there aborts in UITabBarController; the
    /// next update is safe.
    private func updatePlaylistsTab(isRegularWidth: Bool) {
        guard showsPlaylistsTab != isRegularWidth else {
            return
        }
        Task { @MainActor in
            showsPlaylistsTab = isRegularWidth
            leavePlaylistsTabIfCompact()
        }
    }

    /// The compact bar has no Playlists button; if the tab is selected when
    /// the width turns compact, the Library, whose Playlists row reaches the
    /// same screen, takes over.
    private func leavePlaylistsTabIfCompact() {
        if selectedTab == .playlists, horizontalSizeClass == .compact {
            selectedTab = .library
        }
    }

    private func openEpisode(on section: AppSection) -> (String) -> Void {
        { episodeID in
            navigationPaths[section].append(.episodeDetail(id: episodeID))
        }
    }

    private func openPlaylist(on section: AppSection) -> (String) -> Void {
        { playlistID in
            navigationPaths[section].append(.playlistDetail(id: playlistID))
        }
    }

    private var showsTabAccessory: Bool {
        appModel.playback.currentEpisode != nil || appModel.showsUpNextAccessory
    }

    /// One system accessory, two contents: the mini player while an episode
    /// is loaded, otherwise the queue head with a play control.
    @ViewBuilder
    private var tabAccessory: some View {
        if appModel.playback.currentEpisode != nil {
            MiniPlayerView(
                isNowPlayingPresented: isNowPlayingPresented,
                onExpand: onPresentNowPlaying
            )
        } else {
            UpNextAccessoryView(
                isNowPlayingPresented: isNowPlayingPresented,
                onOpenQueue: onOpenUpNext
            )
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
