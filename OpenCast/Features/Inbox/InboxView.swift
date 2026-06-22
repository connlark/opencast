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
    let onOpenSettings: () -> Void
    let onOpenEpisode: (String) -> Void
    var selectsEpisodeDetailOnPlay = false

    private var hasSearchQuery: Bool {
        EpisodeSearch.isSearchActive(query: searchQuery)
    }

    var body: some View {
        let inboxEpisodes = appModel.library.inboxEpisodes
        let searchTaskKey = EpisodeSearchRequestKey(
            episodes: inboxEpisodes,
            query: searchQuery,
            mode: searchMode
        )
        let searchResults = searchSession.displayedResults(for: searchTaskKey)

        List {
            if shouldShowNotificationPromoBanner {
                InboxNotificationPromoBanner(
                    onOpen: openNotificationSettings,
                    onDismiss: dismissNotificationPromo
                )
            }

            if appModel.library.state == .loading && inboxEpisodes.isEmpty {
                InboxLoadingStateView()
            } else if case .failed(let message) = appModel.library.state,
                      inboxEpisodes.isEmpty {
                InboxFailedStateView(message: message)
            } else if inboxEpisodes.isEmpty {
                InboxEmptyStateView(
                    syncActivity: appModel.syncStatus.libraryActivity,
                    onAdd: onAdd
                )
            } else if hasSearchQuery {
                EpisodeSearchResultsContent(
                    mode: searchMode,
                    isLoadingVisible: searchSession.isLoadingVisible,
                    isSearching: searchSession.isSearching,
                    results: searchResults,
                    fallbackEpisodes: inboxEpisodes,
                    selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                    onSelect: dismissSearchKeyboard,
                    onOpenEpisode: onOpenEpisode
                )
            } else {
                ForEach(inboxEpisodes) { episode in
                    EpisodeRowButton(
                        episode: episode,
                        selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                        onSelect: dismissSearchKeyboard,
                        onOpenEpisode: onOpenEpisode
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
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
                episodes: inboxEpisodes,
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

    private func dismissSearchKeyboard() {
        KeyboardDismissal.dismiss()
    }

    private var shouldShowNotificationPromoBanner: Bool {
        !hasSearchQuery
            && appModel.onboardingState.isCompleted
            && !appModel.notificationSettings.isEnabled
            && !appModel.notificationPromoBanner.isResolved
    }

    private func openNotificationSettings() {
        guard appModel.notificationPromoBanner.markResolved(modelContext: modelContext) else {
            return
        }

        onOpenSettings()
    }

    private func dismissNotificationPromo() {
        appModel.notificationPromoBanner.markResolved(modelContext: modelContext)
    }
}
