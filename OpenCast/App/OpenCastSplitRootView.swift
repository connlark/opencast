import SwiftUI

struct OpenCastSplitRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Binding var selectedSection: AppSection?
    @Binding var selectedRoute: AppRoute?
    @State private var detailPath: [AppRoute] = []
    let isNowPlayingPresented: Bool
    let onAdd: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDataNukeConfirmation: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Button {
                    select(section)
                } label: {
                    section.label
                }
                .buttonStyle(.plain)
                .tag(section as AppSection?)
            }
            .navigationTitle("opencast")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus", action: onAdd)
                }
            }
        } content: {
            NavigationStack {
                switch selectedSection ?? .library {
                case .library:
                    LibraryView(
                        usesNavigationLinks: false,
                        onAdd: onAdd,
                        onOpenPodcast: { feedURL in
                            selectRootRoute(.podcastDetail(feedURL: feedURL))
                        }
                    )
                case .inbox:
                    InboxView(
                        onAdd: onAdd,
                        onOpenSettings: onOpenSettings,
                        onOpenEpisode: { episodeID in
                            selectRootRoute(.episodeDetail(id: episodeID))
                        },
                        selectsEpisodeDetailOnPlay: true
                    )
                case .settings:
                    ContentUnavailableView(
                        AppSection.settings.title,
                        systemImage: AppSection.settings.systemImage
                    )
                }
            }
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if selectedSection == .settings {
                        SettingsView(
                            onPresentDataNukeConfirmation: onPresentDataNukeConfirmation
                        )
                    } else if let selectedRoute {
                        RouteDestinationView(
                            route: selectedRoute,
                            selectsEpisodeDetailOnPlay: true
                        ) {
                            invalidateSelectedRoute()
                        } onOpenEpisode: { episodeID in
                            pushEpisodeDetail(episodeID)
                        }
                    } else {
                        ContentUnavailableView(
                            "Select an Item",
                            systemImage: "sidebar.right"
                        )
                    }
                }
                .withOpenCastDestinations(
                    onOpenEpisode: pushEpisodeDetail,
                    selectsEpisodeDetailOnPlay: true
                )
            }
        }
        .onChange(of: selectedSection) { _, _ in
            detailPath.removeAll()
        }
        .onChange(of: selectedRoute) { _, _ in
            detailPath.removeAll()
        }
        .safeAreaInset(edge: .bottom) {
            if appModel.playback.currentEpisode != nil {
                MiniPlayerView(
                    isNowPlayingPresented: isNowPlayingPresented,
                    onExpand: onPresentNowPlaying
                )
            }
        }
    }

    private func select(_ section: AppSection) {
        selectedSection = section
        detailPath.removeAll()
    }

    private func selectRootRoute(_ route: AppRoute) {
        selectedRoute = route
        detailPath.removeAll()
    }

    private func invalidateSelectedRoute() {
        selectedRoute = nil
        detailPath.removeAll()
    }

    private func pushEpisodeDetail(_ episodeID: String) {
        detailPath.append(.episodeDetail(id: episodeID))
    }
}
