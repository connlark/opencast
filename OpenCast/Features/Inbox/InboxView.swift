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
            if appModel.library.inboxEpisodes.isEmpty {
                InboxEmptyStateView(onAdd: onAdd)
            } else if hasSearchQuery {
                if searchSession.isSearching {
                    ProgressView("Searching")
                } else if searchSession.results.isEmpty {
                    ContentUnavailableView.search
                } else {
                    ForEach(searchSession.results) { result in
                        Button {
                            openEpisode(result.episode.episodeID)
                        } label: {
                            EpisodeRowView(episode: result.episode, searchResult: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: result.episode.episodeID))
                    }
                }
            } else {
                ForEach(appModel.library.inboxEpisodes) { episode in
                    Button {
                        openEpisode(episode.episodeID)
                    } label: {
                        EpisodeRowView(episode: episode)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: episode.episodeID))
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
            await searchSession.update(
                episodes: appModel.library.inboxEpisodes,
                query: searchQuery,
                mode: searchMode
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

    private func openEpisode(_ episodeID: String) {
        appModel.requestEpisodeAutoplayOnOpenIfNotListening(episodeID: episodeID)
        onOpenEpisode(episodeID)
    }
}
