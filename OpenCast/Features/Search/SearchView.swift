import OpenCastCore
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Binding var scope: SearchScope
    @Binding var isSearchPresented: Bool

    @State private var query = ""
    @State private var searchSession = EpisodeSearchSession()
    @State private var searchStore: PodcastSearchStore
    @State private var subscriptionFlow: DirectorySubscriptionFlowStore
    @State private var sheetDestination: SheetDestination?

    let onSheetDismissed: () -> Void
    let onOpenEpisode: (String) -> Void
    let onOpenPodcast: (String) -> Void

    init(
        directoryService: any PodcastDirectoryService,
        directoryResolver: DirectoryFeedCandidateResolver = DirectoryFeedCandidateResolver(),
        knownPodcasts: KnownPodcastsStore,
        scope: Binding<SearchScope>,
        isSearchPresented: Binding<Bool>,
        onSheetDismissed: @escaping () -> Void,
        onOpenEpisode: @escaping (String) -> Void,
        onOpenPodcast: @escaping (String) -> Void
    ) {
        _scope = scope
        _isSearchPresented = isSearchPresented
        _searchStore = State(initialValue: PodcastSearchStore(directoryService: directoryService, knownPodcasts: knownPodcasts))
        _subscriptionFlow = State(
            initialValue: DirectorySubscriptionFlowStore(
                directoryService: directoryService,
                resolver: directoryResolver,
                knownPodcasts: knownPodcasts
            )
        )
        self.onSheetDismissed = onSheetDismissed
        self.onOpenEpisode = onOpenEpisode
        self.onOpenPodcast = onOpenPodcast
    }

    var body: some View {
        let episodes = appModel.library.episodes
        let requestKey = EpisodeSearchRequestKey(
            episodes: episodes,
            query: query,
            mode: .fullText,
            corpusRevision: appModel.library.episodeSearchCorpusRevision
        )
        let taskKey = SearchSessionTaskKey(scope: scope, request: requestKey)
        let searchResults = searchSession.displayedResults(for: requestKey)

        List {
            if let typedFeedURL {
                Section {
                    PodcastOpenFeedRow(feedURL: typedFeedURL) {
                        openFeed(typedFeedURL)
                    }
                    .disabled(subscriptionFlow.isBusy)
                }
            }

            if let failure = subscriptionFlow.failure {
                Section {
                    PodcastAddFailureRow(failure: failure, onDismiss: subscriptionFlow.clearError)
                }
            }

            if let recentSearchesErrorMessage = appModel.recentSearches.lastErrorMessage {
                Section {
                    Label(recentSearchesErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if !EpisodeSearch.isSearchActive(query: query) {
                if appModel.recentSearches.queries.isEmpty {
                    ContentUnavailableView(
                        "No Recent Searches",
                        systemImage: "clock",
                        description: Text("Search your library or discover a podcast.")
                    )
                } else {
                    SearchRecentQueriesSection(
                        queries: appModel.recentSearches.queries,
                        onSelect: runRecentQuery,
                        onClear: clearRecentSearches
                    )
                }
            } else if !PodcastFeedURLDetector.isAddressLike(query) {
                switch scope {
                case .library:
                    if searchSession.isIndexedSearchUnavailable {
                        SearchIndexUpdatingIndicator()
                    }
                    EpisodeSearchResultsContent(
                        mode: .fullText,
                        isLoadingVisible: searchSession.isLoadingVisible,
                        isSearching: searchSession.isSearching,
                        results: searchResults,
                        fallbackEpisodes: []
                    ) { episode, result in
                        EpisodeRowButton(
                            episode: episode,
                            searchResult: result,
                            onSelect: handleResultSelection,
                            onOpenEpisode: onOpenEpisode
                        )
                    }
                case .discover:
                    SearchDiscoverResultsSection(
                        searchStore: searchStore,
                        subscriptionFlow: subscriptionFlow,
                        knownPodcasts: appModel.knownPodcasts,
                        activePodcastIDs: appModel.library.activePodcastIDs,
                        onPreview: preview,
                        onQuickAdd: quickAdd,
                        onOpenPodcast: openPodcast
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            prompt: "Podcasts and Episodes"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .searchScopes($scope) {
            SearchScopePicker()
        }
        .sheet(item: $sheetDestination, onDismiss: onSheetDismissed) { destination in
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
        }
        .onSubmit(of: .search, recordRecentSearch)
        .onChange(of: appModel.systemSearchRequest, initial: true) { _, request in
            guard let request else { return }
            query = request.query
            appModel.systemSearchRequest = nil
        }
        .onChange(of: query) { _, _ in
            synchronizeDirectorySearch()
        }
        .onChange(of: scope) { _, _ in
            synchronizeDirectorySearch()
        }
        .onChange(of: subscriptionFlow.pendingChoice?.id) { _, _ in
            presentHandedOffChoice()
        }
        .task(id: taskKey) {
            guard scope == .library, !PodcastFeedURLDetector.isAddressLike(query) else {
                return
            }

            let library = appModel.library
            await searchSession.update(
                episodes: episodes,
                query: query,
                mode: .fullText,
                corpusRevision: library.episodeSearchCorpusRevision,
                indexedSearchProvider: {
                    await library.searchEpisodes(
                        query: query,
                        mode: .fullText
                    )
                },
                showNotesProvider: { await library.showNotesHTMLByEpisodeID() }
            )
        }
        .onAppear(perform: subscriptionFlow.presenterDidAppear)
        .onDisappear(perform: handleDisappear)
    }

    private var typedFeedURL: URL? {
        PodcastFeedURLDetector.openableFeedURL(from: query)
    }

    private func handleDisappear() {
        searchStore.cancelSearch()
        subscriptionFlow.presenterDidDisappear(library: appModel.library, modelContext: modelContext)
    }

    private func synchronizeDirectorySearch() {
        guard scope == .discover else {
            searchStore.cancelSearch()
            searchStore.query = ""
            return
        }

        searchStore.query = query
    }

    private func recordRecentSearch() {
        appModel.recentSearches.record(query, modelContext: modelContext)
    }

    private func handleResultSelection() {
        recordRecentSearch()
        KeyboardDismissal.dismiss()
    }

    private func runRecentQuery(_ recentQuery: String) {
        query = recentQuery
        appModel.recentSearches.record(recentQuery, modelContext: modelContext)
    }

    private func clearRecentSearches() {
        appModel.recentSearches.clear(modelContext: modelContext)
    }

    private func openPodcast(_ feedURLString: String) {
        handleResultSelection()
        onOpenPodcast(feedURLString)
    }

    private func preview(_ result: DirectoryPodcastResult) {
        KeyboardDismissal.dismiss()
        present(PodcastPreviewRequest(subject: .result(result)))
    }

    private func openFeed(_ feedURL: URL) {
        let request = PodcastPreviewRequest(subject: .feedURL(feedURL))
        if let libraryFeedURL = appModel.knownPodcasts.libraryFeedURL(
            for: request.knownPodcastKey,
            activePodcastIDs: appModel.library.activePodcastIDs
        ) {
            openPodcast(libraryFeedURL)
        } else {
            KeyboardDismissal.dismiss()
            present(request)
        }
    }

    private func presentHandedOffChoice() {
        guard let request = subscriptionFlow.handOffChoice() else {
            return
        }
        present(request)
    }

    private func present(_ request: PodcastPreviewRequest) {
        sheetDestination = .podcastPreview(
            request,
            PodcastPreviewPresenter(
                addFlow: subscriptionFlow,
                onSubscribed: recordRecentSearch,
                afterSubscribe: .offersGoToShow(goToShow)
            )
        )
    }

    private func quickAdd(_ result: DirectoryPodcastResult) {
        KeyboardDismissal.dismiss()
        subscriptionFlow.subscribe(
            to: result,
            library: appModel.library,
            modelContext: modelContext,
            onSubscribed: recordRecentSearch
        )
    }

    private func goToShow(_ feedURLString: String) {
        sheetDestination = nil
        onOpenPodcast(feedURLString)
    }

    private func dismissSheet() {
        sheetDestination = nil
    }
}
