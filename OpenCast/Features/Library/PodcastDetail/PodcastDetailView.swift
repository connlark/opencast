import SwiftUI

struct PodcastDetailView: View {
    /// Overscroll past a search-bar's worth of travel opens search; the list has no
    /// pull-to-refresh so the gesture is unambiguous.
    private static let pullToSearchDistance: Double = 72

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var feedMigrationErrorMessage: String?
    @State private var isShowingFeedMigrationError = false
    @State private var isConfirmingUnsubscribe = false
    @State private var isConfirmingAdAutoDetect = false
    @State private var isConfirmingMarkAllPlayed = false
    @State private var isConfirmingDeleteAllDownloads = false
    @State private var searchQuery = ""
    @State private var isSearchVisible = false
    @State private var isSearchPresented = false
    @State private var searchMode: EpisodeSearchMode = .episodes
    @State private var searchSession = EpisodeSearchSession()

    let feedURL: String
    var onOpenEpisode: (String) -> Void = { _ in }

    private var subscription: SubscriptionRecord? {
        appModel.library.subscriptions.first { $0.feedURL == feedURL }
    }

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: feedURL)
    }

    private var hasSearchQuery: Bool {
        EpisodeSearch.isSearchActive(query: searchQuery)
    }

    private var searchPrompt: String {
        guard let subscription else {
            return "Search Podcast"
        }
        return "Search \(subscription.title)"
    }

    private var isRefreshing: Bool {
        appModel.library.isRefreshing(feedURL: feedURL)
    }

    private var refreshErrorMessage: String? {
        guard let errorMessage = appModel.library.latestRefreshLog(feedURL: feedURL)?.errorMessage,
              !errorMessage.isEmpty
        else {
            return nil
        }
        return errorMessage
    }

    var body: some View {
        let allEpisodes = appModel.library.episodes(forPodcastID: feedURL)
        let sortOrder = appModel.podcastEpisodeListSettings.sortOrder(forPodcastID: feedURL)
        let filter = appModel.podcastEpisodeListSettings.filter(forPodcastID: feedURL)
        let model = PodcastEpisodeListModel.make(
            episodes: allEpisodes,
            filter: filter,
            sortOrder: sortOrder,
            library: appModel.library,
            downloadRecords: appModel.downloads.records
        )
        let unplayedEpisodeCount = allEpisodes.count { episode in
            !appModel.library.progressSummary(for: episode).isCompleted
        }
        let downloadCount = appModel.downloads.records.count { $0.podcastID == feedURL }
        let primaryAction = PodcastPrimaryAction.resolve(
            episodes: allEpisodes,
            library: appModel.library
        )
        let searchTaskKey = EpisodeSearchRequestKey(
            episodes: allEpisodes,
            query: searchQuery,
            mode: searchMode,
            corpusRevision: appModel.library.episodeSearchCorpusRevision
        )
        let searchResults = searchSession.displayedResults(for: searchTaskKey)

        Group {
            if let subscription {
                List {
                    if !isSearchVisible {
                        Section {
                            VStack(spacing: 16) {
                                PodcastHeroHeaderView(
                                    subscription: subscription,
                                    podcast: podcastCache,
                                    episodeCount: allEpisodes.count,
                                    unplayedCount: unplayedEpisodeCount,
                                    lastRefreshedAt: appModel.library.lastRefreshedAt(for: subscription),
                                    isRefreshing: isRefreshing,
                                    refreshErrorMessage: refreshErrorMessage,
                                    health: FeedHealthStatus.derive(
                                        latestLog: appModel.library.latestRefreshLog(feedURL: feedURL),
                                        latestSuccessAt: appModel.library.latestSuccessfulRefreshByFeedURL[feedURL],
                                        contentChangedAt: podcastCache?.updatedAt
                                    ),
                                    notificationHealth: appModel.library.notificationFeedHealthByFeedURL[feedURL],
                                    primaryAction: primaryAction,
                                    onPlay: playPrimaryAction,
                                    onPreviewResolved: updatePodcastArtworkPreview
                                )
                                if let suggestedFeedURL = appModel.library.suggestedFeedMigrationURLsByFeedURL[feedURL] {
                                    FeedAddressUpdateView(
                                        suggestedFeedURL: suggestedFeedURL,
                                        onUpdate: updateFeedAddress
                                    )
                                }
                                PodcastEpisodeListControlsView(
                                    sortOrder: sortOrderBinding,
                                    filter: filterBinding,
                                    podcastID: feedURL
                                )
                            }
                            .frame(maxWidth: 600)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("Podcast Hero Header")
                        }
                    }

                    Section("Episodes") {
                        if allEpisodes.isEmpty {
                            ContentUnavailableView(
                                "No Episodes Yet",
                                systemImage: "waveform",
                                description: Text("This show hasn't published any episodes. New episodes will appear here automatically.")
                            )
                        } else if hasSearchQuery {
                            if searchSession.isIndexedSearchUnavailable {
                                SearchIndexUpdatingIndicator(mode: searchMode)
                            }
                            EpisodeSearchResultsContent(
                                mode: searchMode,
                                isLoadingVisible: searchSession.isLoadingVisible,
                                isSearching: searchSession.isSearching,
                                results: searchResults,
                                fallbackEpisodes: allEpisodes
                            ) { episode, result in
                                EpisodeRowButton(
                                    episode: episode,
                                    searchResult: result,
                                    showsLocalStatusBadges: true,
                                    showsGoToShow: false,
                                    onSelect: dismissSearchKeyboard,
                                    onOpenEpisode: onOpenEpisode
                                )
                                .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode))
                            }
                        } else if model.isFilteredEmpty {
                            ContentUnavailableView {
                                Label(filter.emptyStateTitle, systemImage: filter.systemImage)
                            } description: {
                                Text(filter.emptyStateDescription)
                            } actions: {
                                Button("Show All Episodes", action: showAllEpisodes)
                            }
                        } else {
                            ForEach(model.episodes) { episode in
                                EpisodeRowButton(
                                    episode: episode,
                                    showsLocalStatusBadges: true,
                                    showsGoToShow: false,
                                    onSelect: dismissSearchKeyboard,
                                    onOpenEpisode: onOpenEpisode
                                )
                                .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode))
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .scrollContentBackground(.hidden)
                .background(alignment: .top) {
                    EpisodeArtworkGlowBackground(preview: podcastCache?.artworkPreview)
                }
                .contentMargins(.bottom, 72, for: .scrollContent)
                .animation(listAnimation, value: model.animationKey)
                .animation(listAnimation, value: appModel.library.state)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top < -Self.pullToSearchDistance
                } action: { _, isPulledPastSearchThreshold in
                    if isPulledPastSearchThreshold {
                        showSearch()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Podcast Not Found", systemImage: "questionmark.circle")
                } description: {
                    Text("This subscription is no longer in your library.")
                } actions: {
                    Button("Go Back", systemImage: "chevron.backward", action: dismiss.callAsFunction)
                }
            }
        }
        .navigationTitle(subscription?.title ?? "Podcast")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(
            EpisodeSearchPresentationModifier(
                isSearchVisible: isSearchVisible,
                prompt: searchPrompt,
                searchQuery: $searchQuery,
                isSearchPresented: $isSearchPresented,
                searchMode: $searchMode,
                isFullTextSearchAvailable: !searchSession.isIndexedSearchUnavailable
            )
        )
        .onChange(of: isSearchPresented) { _, isPresented in
            if !isPresented {
                hideSearch()
            }
        }
        .alert("Feed Address Update Failed", isPresented: $isShowingFeedMigrationError) {
        } message: {
            Text(feedMigrationErrorMessage ?? "The new feed address could not be loaded.")
        }
        .task(id: searchTaskKey) {
            let library = appModel.library
            let podcastID = feedURL
            await searchSession.update(
                episodes: allEpisodes,
                query: searchQuery,
                mode: searchMode,
                corpusRevision: library.episodeSearchCorpusRevision,
                indexedSearchProvider: {
                    await library.searchEpisodes(
                        query: searchQuery,
                        mode: searchMode,
                        forPodcastID: podcastID
                    )
                },
                showNotesProvider: { await library.showNotesHTMLByEpisodeID(forPodcastID: podcastID) }
            )
        }
        .toolbar {
            if let subscription {
                ToolbarItem(placement: .primaryAction) {
                    PodcastActionsMenu(
                        subscription: subscription,
                        podcast: podcastCache,
                        isRefreshing: isRefreshing,
                        unplayedEpisodeCount: unplayedEpisodeCount,
                        downloadCount: downloadCount,
                        onSearch: showSearch,
                        adAutoDetectBinding: adAutoDetectBinding,
                        isConfirmingAdAutoDetect: $isConfirmingAdAutoDetect,
                        isConfirmingMarkAllPlayed: $isConfirmingMarkAllPlayed,
                        isConfirmingDeleteAllDownloads: $isConfirmingDeleteAllDownloads,
                        isConfirmingUnsubscribe: $isConfirmingUnsubscribe
                    )
                }
            }
        }
    }

    private var listAnimation: Animation? {
        hasSearchQuery || reduceMotion ? nil : .default
    }

    private var sortOrderBinding: Binding<PodcastEpisodeSortOrder> {
        Binding(
            get: { appModel.podcastEpisodeListSettings.sortOrder(forPodcastID: feedURL) },
            set: { sortOrder in
                appModel.podcastEpisodeListSettings.setSortOrder(
                    sortOrder,
                    forPodcastID: feedURL,
                    modelContext: modelContext
                )
            }
        )
    }

    private var filterBinding: Binding<PodcastEpisodeFilter> {
        Binding(
            get: { appModel.podcastEpisodeListSettings.filter(forPodcastID: feedURL) },
            set: { filter in
                appModel.podcastEpisodeListSettings.setFilter(
                    filter,
                    forPodcastID: feedURL,
                    modelContext: modelContext
                )
            }
        )
    }

    private var adAutoDetectBinding: Binding<Bool> {
        Binding(
            get: { subscription?.isAdAutoDetectEnabled ?? false },
            set: { isEnabled in
                if isEnabled {
                    isConfirmingAdAutoDetect = true
                } else {
                    setAdAutoDetectEnabled(false)
                }
            }
        )
    }

    private func setAdAutoDetectEnabled(_ isEnabled: Bool) {
        appModel.library.setAdAutoDetectEnabled(
            isEnabled,
            feedURL: feedURL,
            modelContext: modelContext
        )
    }

    private func updateFeedAddress() {
        guard let suggestedFeedURL = appModel.library.suggestedFeedMigrationURLsByFeedURL[feedURL] else {
            return
        }
        Task {
            do {
                try await appModel.library.migrateSubscription(
                    from: feedURL,
                    toFeedURL: suggestedFeedURL,
                    modelContext: modelContext
                )
                // The route still points at the old feed URL; the migrated
                // show is reachable from the library under its new address.
                dismiss()
            } catch is CancellationError {
            } catch {
                feedMigrationErrorMessage = error.localizedDescription
                isShowingFeedMigrationError = true
            }
        }
    }

    private func playPrimaryAction(_ episode: EpisodeListItemSnapshot) {
        do {
            try appModel.playEpisode(episode, modelContext: modelContext)
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    private func showAllEpisodes() {
        appModel.podcastEpisodeListSettings.setFilter(
            .all,
            forPodcastID: feedURL,
            modelContext: modelContext
        )
    }

    private func updatePodcastArtworkPreview(_ preview: ArtworkPreview) {
        guard let podcastCache else {
            return
        }
        appModel.library.updateArtworkPreview(preview, for: podcastCache)
    }

    private func showSearch() {
        guard !isSearchVisible else {
            return
        }
        searchQuery = ""
        searchMode = .episodes
        searchSession.clear()
        isSearchVisible = true
        isSearchPresented = true
    }

    private func hideSearch() {
        isSearchVisible = false
        searchQuery = ""
        searchMode = .episodes
        searchSession.clear()
    }

    private func dismissSearchKeyboard() {
        KeyboardDismissal.dismiss()
    }
}
