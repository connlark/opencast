import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var searchQuery = ""
    @State private var isSearchVisible = false
    @State private var isSearchPresented = false
    @State private var searchMode: EpisodeSearchMode = .episodes
    @State private var searchSession = EpisodeSearchSession()

    let onAdd: () -> Void
    let onOpenEpisode: (String) -> Void
    var selectsEpisodeDetailOnPlay = false

    private var hasSearchQuery: Bool {
        EpisodeSearch.isSearchActive(query: searchQuery)
    }

    private var searchTaskKey: EpisodeSearchRequestKey {
        EpisodeSearchRequestKey(
            episodes: appModel.library.inboxEpisodes,
            query: searchQuery,
            mode: searchMode
        )
    }

    var body: some View {
        List {
            if appModel.library.state == .loading && appModel.library.inboxEpisodes.isEmpty {
                InboxLoadingStateView()
            } else if case .failed(let message) = appModel.library.state,
                      appModel.library.inboxEpisodes.isEmpty {
                InboxFailedStateView(message: message)
            } else if appModel.library.inboxEpisodes.isEmpty {
                InboxEmptyStateView(onAdd: onAdd)
            } else if hasSearchQuery {
                if searchSession.isSearching {
                    ProgressView("Searching")
                } else if searchSession.results.isEmpty {
                    ContentUnavailableView.search
                } else {
                    ForEach(searchSession.results) { result in
                        EpisodeRowButton(
                            episode: result.episode,
                            searchResult: result,
                            selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                            onOpenEpisode: onOpenEpisode
                        )
                    }
                }
            } else {
                ForEach(appModel.library.inboxEpisodes) { episode in
                    EpisodeRowButton(
                        episode: episode,
                        selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                        onOpenEpisode: onOpenEpisode
                    )
                }
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass", action: showSearch)
            }
        }
        .modifier(
            InboxSearchPresentationModifier(
                isSearchVisible: isSearchVisible,
                searchQuery: $searchQuery,
                isSearchPresented: $isSearchPresented,
                searchMode: $searchMode
            )
        )
        .onChange(of: isSearchPresented) { _, isPresented in
            if !isPresented {
                hideSearch()
            }
        }
        .task(id: searchTaskKey) {
            let library = appModel.library
            await searchSession.update(
                episodes: library.inboxEpisodes,
                query: searchQuery,
                mode: searchMode,
                showNotesProvider: { await library.showNotesHTMLByEpisodeID() }
            )
        }
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
    }

    private func showSearch() {
        isSearchVisible = true
        isSearchPresented = true
    }

    private func hideSearch() {
        isSearchVisible = false
        searchQuery = ""
        searchMode = .episodes
        searchSession.clear()
    }
}
