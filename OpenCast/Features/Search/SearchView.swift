import OpenCastCore
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var query = ""
    @State private var scope = SearchScope.library
    @State private var searchSession = EpisodeSearchSession()
    @State private var searchStore: PodcastSearchStore
    @State private var subscribingFeedURLString: String?
    @State private var subscriptionErrorMessage: String?

    let onOpenEpisode: (String) -> Void
    let onOpenPodcast: (String) -> Void

    init(
        directoryService: any PodcastDirectoryService,
        onOpenEpisode: @escaping (String) -> Void,
        onOpenPodcast: @escaping (String) -> Void
    ) {
        _searchStore = State(initialValue: PodcastSearchStore(directoryService: directoryService))
        self.onOpenEpisode = onOpenEpisode
        self.onOpenPodcast = onOpenPodcast
    }

    var body: some View {
        let episodes = appModel.library.episodes
        let requestKey = EpisodeSearchRequestKey(
            episodes: episodes,
            query: query,
            mode: .fullText
        )
        let taskKey = SearchSessionTaskKey(scope: scope, request: requestKey)
        let searchResults = searchSession.displayedResults(for: requestKey)

        List {
            if let feedURLString = PodcastFeedURLDetector.feedURLString(from: query) {
                SearchAddFeedSection(
                    feedURLString: feedURLString,
                    activePodcastIDs: appModel.library.activePodcastIDs,
                    subscribingFeedURLString: subscribingFeedURLString,
                    onAdd: { subscribe(to: feedURLString) }
                )
            }

            if let subscriptionErrorMessage {
                Section {
                    Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
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
            } else {
                switch scope {
                case .library:
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
                        activePodcastIDs: appModel.library.activePodcastIDs,
                        subscribingFeedURLString: subscribingFeedURLString,
                        onSubscribe: subscribe,
                        onOpenPodcast: openPodcast
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Podcasts and Episodes")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .searchScopes($scope) {
            SearchScopePicker()
        }
        .onSubmit(of: .search, recordRecentSearch)
        .onChange(of: query) { _, _ in
            synchronizeDirectorySearch()
        }
        .onChange(of: scope) { _, _ in
            synchronizeDirectorySearch()
        }
        .task(id: taskKey) {
            guard scope == .library else {
                return
            }

            let library = appModel.library
            await searchSession.update(
                episodes: episodes,
                query: query,
                mode: .fullText,
                showNotesProvider: { await library.showNotesHTMLByEpisodeID() }
            )
        }
        .onDisappear(perform: searchStore.cancelSearch)
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

    private func subscribe(to result: DirectoryPodcastResult) {
        guard let feedURLString = result.feedURLString else {
            return
        }

        subscribe(to: feedURLString)
    }

    private func subscribe(to feedURLString: String) {
        guard subscribingFeedURLString == nil else {
            return
        }

        KeyboardDismissal.dismiss()
        Task {
            await performSubscription(to: feedURLString)
        }
    }

    private func performSubscription(to feedURLString: String) async {
        subscriptionErrorMessage = nil
        subscribingFeedURLString = feedURLString
        defer {
            subscribingFeedURLString = nil
        }

        do {
            try await appModel.library.subscribe(to: feedURLString, modelContext: modelContext)
            recordRecentSearch()
        } catch is CancellationError {
        } catch {
            subscriptionErrorMessage = error.localizedDescription
        }
    }
}
