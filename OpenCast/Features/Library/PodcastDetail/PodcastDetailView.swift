import SwiftData
import SwiftUI

struct PodcastDetailView: View {
    @State private var visibleEpisodeCount = EpisodeCatalogContinuation.pageSize
    /// Overscroll past a search-bar's worth of travel opens search; the list has no
    /// pull-to-refresh so the gesture is unambiguous.
    private static let pullToSearchDistance: Double = 72

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Set when this page is a two-pane split's detail root, where `dismiss`
    /// cannot remove it.
    @Environment(\.twoPaneRootClose) private var rootClose
    /// Inside a two-pane root, the visit ledger above its containers.
    @Environment(\.twoPaneRootVisit) private var rootVisit
    @State private var feedMigrationErrorMessage: String?
    @State private var isShowingFeedMigrationError = false
    @State private var isConfirmingUnsubscribe = false
    @State private var isConfirmingAdAutoDetect = false
    @State private var isConfirmingMarkAllPlayed = false
    @State private var isConfirmingDeleteAllDownloads = false
    @State private var isSearchPresented = false
    @State private var searchSession = EpisodeSearchSession()
    @State private var sheetDestination: SheetDestination?
    /// This visit's settings in the page's own state: the truth when no
    /// two-pane root holds the visit, a mirror of the ledger's when one does.
    @State private var localVisit: PodcastDetailVisit

    let feedURL: String
    let onOpenEpisode: (String) -> Void
    /// The route this page was opened with: its identity, and the key of
    /// its visit in a two-pane root's ledger.
    private let route: AppRoute

    init(
        feedURL: String,
        episodeListOverride: PodcastEpisodeListOverride? = nil,
        onOpenEpisode: @escaping (String) -> Void = { _ in }
    ) {
        self.feedURL = feedURL
        self.onOpenEpisode = onOpenEpisode
        let route = AppRoute.podcastDetail(feedURL: feedURL, episodeListOverride: episodeListOverride)
        self.route = route
        _localVisit = State(initialValue: PodcastDetailVisit(route: route))
    }

    /// The visit as a two-pane root's ledger holds it, above its containers,
    /// so a fold or rotation that rebuilds this page keeps it. Nil outside a
    /// two-pane root, and while the path holds this route more than once.
    private var ledgerVisit: PodcastDetailVisit? {
        rootVisit?.podcastDetailVisit(for: route)
    }

    private var visit: PodcastDetailVisit {
        ledgerVisit ?? localVisit
    }

    private func updateVisit(_ change: (inout PodcastDetailVisit) -> Void) {
        var updated = visit
        change(&updated)
        localVisit = updated
        if ledgerVisit != nil {
            rootVisit?.setPodcastDetailVisit(updated, for: route)
        }
    }

    /// The Inbox settings a Group by Podcast tap opened this visit under.
    /// They win over the show's stored filter without being written to it,
    /// and end with the first filter pick here.
    private var episodeListOverride: PodcastEpisodeListOverride? {
        visit.episodeListOverride
    }

    private var isSearchVisible: Bool {
        visit.search != nil
    }

    private var searchQuery: String {
        visit.search?.query ?? ""
    }

    private var searchMode: EpisodeSearchMode {
        visit.search?.mode ?? .episodes
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { searchQuery },
            set: { query in
                updateVisit { $0.search?.query = query }
            }
        )
    }

    private var searchModeBinding: Binding<EpisodeSearchMode> {
        Binding(
            get: { searchMode },
            set: { mode in
                updateVisit { $0.search?.mode = mode }
            }
        )
    }

    private var filter: PodcastEpisodeFilter {
        episodeListOverride?.filter ?? appModel.podcastEpisodeListSettings.filter(forPodcastID: feedURL)
    }

    private var hidesQueuedEpisodes: Bool {
        episodeListOverride?.hidesQueuedEpisodes ?? false
    }

    private var archiveScope: PodcastEpisodeArchiveScope {
        episodeListOverride?.archiveScope ?? .all
    }

    /// What this visit keeps off the list, as the Inbox view it came from
    /// does: Up Next plus the playing episode, and the show's archived
    /// episodes (from the Inbox) or those not archived (from the archive).
    /// Reads the queue, player and archived set only while hiding by them.
    private func episodesHiddenByVisit(
        in episodes: [EpisodeListItemSnapshot]
    ) -> (kinds: PodcastHiddenEpisodes, episodeIDs: Set<String>) {
        var kinds = PodcastHiddenEpisodes()
        var episodeIDs = Set<String>()
        if hidesQueuedEpisodes {
            kinds.queued = true
            episodeIDs = Set(appModel.upNextQueue.items.map(\.episodeID))
            if let playingEpisodeID = appModel.playback.currentEpisode?.id.rawValue {
                episodeIDs.insert(playingEpisodeID)
            }
        }
        if archiveScope != .all {
            let archivedEpisodeIDs = appModel.library.archivedEpisodeIDs
            let hidesArchived = archiveScope == .hidingArchived
            let hiddenHere = episodes.lazy.map(\.episodeID).filter { archivedEpisodeIDs.contains($0) == hidesArchived }
            if !hiddenHere.isEmpty {
                kinds.archived = hidesArchived
                kinds.unarchived = !hidesArchived
                episodeIDs.formUnion(hiddenHere)
            }
        }
        return (kinds, episodeIDs)
    }

    private var subscription: SubscriptionRecord? {
        appModel.library.subscriptions.first { $0.feedURL == feedURL }
    }

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: feedURL)
    }

    private var podcastArtworkPreview: ArtworkPreview? {
        podcastCache.flatMap { appModel.library.artworkPreview(for: $0) }
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
        let filter = filter
        let (hiddenEpisodes, hiddenEpisodeIDs) = episodesHiddenByVisit(in: allEpisodes)
        let model = PodcastEpisodeListModel.make(
            episodes: allEpisodes,
            filter: filter,
            sortOrder: sortOrder,
            library: appModel.library,
            downloadRecords: appModel.downloads.records,
            hiddenEpisodeIDs: hiddenEpisodeIDs
        )
        let downloadCount = appModel.downloads.records.count { $0.podcastID == feedURL }
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
                                    artworkPreview: podcastArtworkPreview,
                                    episodeCount: allEpisodes.count,
                                    unplayedCount: model.unplayedEpisodeCount,
                                    lastRefreshedAt: appModel.library.lastRefreshedAt(for: subscription),
                                    isRefreshing: isRefreshing,
                                    refreshErrorMessage: refreshErrorMessage,
                                    health: FeedHealthStatus.derive(
                                        latestLog: appModel.library.latestRefreshLog(feedURL: feedURL),
                                        latestSuccessAt: appModel.library.latestSuccessfulRefreshByFeedURL[feedURL],
                                        contentChangedAt: appModel.library.lastContentChangedAt(for: feedURL)
                                    ),
                                    notificationHealth: appModel.library.notificationFeedHealthByFeedURL[feedURL],
                                    primaryAction: model.primaryAction,
                                    onPlay: playPrimaryAction,
                                    onPreviewResolved: updatePodcastArtworkPreview
                                )
                                if let reason = appModel.library.incompleteFeeds[feedURL] {
                                    IncompleteFeedNotice(reason: reason, isRefreshing: isRefreshing) {
                                        appModel.library.requestManualRefresh(
                                            feedURL: feedURL,
                                            modelContext: modelContext
                                        )
                                    }
                                }
                                if appModel.library.lastRefreshWasOffline {
                                    LibraryOfflineNotice()
                                }
                                if let suggestedFeedURL = appModel.library.suggestedFeedMigrationURLsByFeedURL[feedURL] {
                                    FeedAddressUpdateView(
                                        suggestedFeedURL: suggestedFeedURL,
                                        onUpdate: updateFeedAddress
                                    )
                                }
                                PodcastEpisodeListControlsView(
                                    sortOrder: sortOrderBinding,
                                    filter: filterBinding,
                                    podcastID: feedURL,
                                    hiddenEpisodes: hiddenEpisodes,
                                    onShowHiddenEpisodes: showHiddenEpisodes
                                )
                            }
                            .frame(maxWidth: 600)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                            .listRowInsets(.top, 0)
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
                                .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode, showsArchiveAction: true))
                            }
                        } else if model.isFilteredEmpty {
                            ContentUnavailableView {
                                Label(filter.emptyStateTitle, systemImage: filter.systemImage)
                            } description: {
                                Text(hiddenEpisodes.filteredEmptyDescription(filter: filter))
                            } actions: {
                                Button(action: showAllEpisodes) {
                                    Text("Show All Episodes")
                                        .frame(minHeight: 44)
                                        .contentShape(.rect)
                                }
                            }
                            // A List row fires a default-style button on a tap anywhere in it;
                            // a borderless one takes only its label's 44 pt target.
                            .buttonStyle(.borderless)
                        } else {
                            ForEach(model.episodes.prefix(visibleEpisodeCount)) { episode in
                                EpisodeRowButton(
                                    episode: episode,
                                    showsLocalStatusBadges: true,
                                    showsGoToShow: false,
                                    onSelect: dismissSearchKeyboard,
                                    onOpenEpisode: onOpenEpisode
                                )
                                .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode, showsArchiveAction: true))
                            }
                            EpisodeCatalogContinuation(totalCount: model.episodes.count, visibleCount: $visibleEpisodeCount)
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .scrollContentBackground(.hidden)
                .background(alignment: .top) {
                    EpisodeArtworkGlowBackground(preview: podcastArtworkPreview)
                }
                .tabAccessoryBottomClearance()
                .animation(listAnimation, value: Array(model.animationKey.prefix(visibleEpisodeCount)))
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
                    Button("Go Back", systemImage: "chevron.backward", action: close)
                }
            }
        }
        // The hero already shows the name, so the bar drops it; the title
        // still names this screen for back navigation and accessibility.
        .navigationTitle(subscription?.title ?? "Podcast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .modifier(
            EpisodeSearchPresentationModifier(
                isSearchVisible: isSearchVisible,
                prompt: searchPrompt,
                searchQuery: searchQueryBinding,
                isSearchPresented: $isSearchPresented,
                searchMode: searchModeBinding,
                isFullTextSearchAvailable: !searchSession.isIndexedSearchUnavailable
            )
        )
        .onChange(of: isSearchPresented) { _, isPresented in
            if !isPresented {
                hideSearch()
            }
        }
        .onChange(of: ledgerVisit, initial: true) { _, ledgerVisit in
            // The page's own state follows the ledger's visit, so it holds
            // the visit's settings should the ledger stop holding this route.
            if let ledgerVisit {
                localVisit = ledgerVisit
            }
        }
        .onAppear {
            // A search this visit kept through a rebuild (a two-pane switch)
            // comes back active, as it was.
            if isSearchVisible, !isSearchPresented {
                isSearchPresented = true
            }
        }
        .alert("Feed Address Update Failed", isPresented: $isShowingFeedMigrationError) {
        } message: {
            Text(feedMigrationErrorMessage ?? "The new feed address could not be loaded.")
        }
        .sheet(item: $sheetDestination) { destination in
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
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
                        unplayedEpisodeCount: model.unplayedEpisodeCount,
                        downloadCount: downloadCount,
                        onSearch: showSearch,
                        onPlaybackSettings: showPlaybackSettings,
                        onDownloadSettings: showDownloadSettings,
                        onMakePlaylist: makePlaylistAction(episodeCount: allEpisodes.count),
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

    private func showPlaybackSettings() {
        sheetDestination = .podcastPlaybackSettings(feedURL: feedURL)
    }

    private func showDownloadSettings() {
        sheetDestination = .podcastDownloadSettings(feedURL: feedURL)
    }

    private func makePlaylistAction(episodeCount: Int) -> (() -> Void)? {
        guard appModel.transcriptIntelligence.isVisible,
              PlaylistOrganizerFeatureFlags.isEnabledForProcess,
              episodeCount >= PlaylistOrganizerFeatureFlags.minimumEpisodeCount
        else {
            return nil
        }
        return showPlaylistOrganizer
    }

    private func showPlaylistOrganizer() {
        sheetDestination = .playlistOrganizer(podcastID: feedURL)
    }

    private func dismissSheet() {
        sheetDestination = nil
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
            get: { filter },
            set: { filter in
                setFilter(filter)
            }
        )
    }

    /// A pick here ends the visit's Inbox settings, Hide Up Next included.
    private func setFilter(_ filter: PodcastEpisodeFilter) {
        updateVisit { $0.episodeListOverride = nil }
        appModel.podcastEpisodeListSettings.setFilter(
            filter,
            forPodcastID: feedURL,
            modelContext: modelContext
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
                close()
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
        setFilter(.all)
    }

    /// Keeps the visit's filter and brings back every row it hid.
    private func showHiddenEpisodes() {
        updateVisit {
            $0.episodeListOverride?.hidesQueuedEpisodes = false
            $0.episodeListOverride?.archiveScope = .all
        }
    }

    /// Leaves this page: a pushed page pops; a two-pane split's detail root
    /// clears its section's path, since `dismiss` cannot remove a stack's
    /// root.
    private func close() {
        if let rootClose, rootClose.route == route {
            rootClose.close()
        } else {
            dismiss()
        }
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
        updateVisit { $0.search = PodcastDetailVisit.Search() }
        searchSession.clear()
        isSearchPresented = true
    }

    private func hideSearch() {
        updateVisit { $0.search = nil }
        searchSession.clear()
    }

    private func dismissSearchKeyboard() {
        KeyboardDismissal.dismiss()
    }
}
