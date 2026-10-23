import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    @State private var searchQuery = ""
    @State private var isSearchVisible = false
    @State private var isSearchPresented = false
    @State private var searchMode: EpisodeSearchMode = .episodes
    @State private var searchSession = EpisodeSearchSession()
    @State private var showsUnplayedOnly = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedEpisodeIDs: Set<String> = []
    @State private var isConfirmingDeleteSelected = false
    @State private var isConfirmingEditRemovePlayed = false
    /// Group by Show sections collapsed this session.
    @State private var collapsedShowIDs: Set<String> = []

    let onOpenEpisode: (String) -> Void

    var body: some View {
        let allDownloads = DownloadsListModel.make(
            records: appModel.downloads.records,
            library: appModel.library
        )
        let model = showsUnplayedOnly
            ? allDownloads.filteringUnplayed(using: appModel.library)
            : allDownloads
        let downloadedEpisodes = model.downloaded.map(\.episode)
        // The model already uniques items per episode ID; uniquing again keeps
        // bad persisted data from ever trapping the whole screen.
        let downloadedItemsByID = Dictionary(
            model.downloaded.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let searchTaskKey = EpisodeSearchRequestKey(
            episodes: downloadedEpisodes,
            query: searchQuery,
            mode: searchMode
        )
        let searchResults = searchSession.displayedResults(for: searchTaskKey)
        let library = appModel.library
        let grouping = appModel.downloadSettings.listGrouping
        // A search lists matches across shows, as the Inbox does.
        let showGroups = grouping == .byShow && !hasSearchQuery
            ? DownloadsShowGroup.make(
                items: model.downloaded,
                isSubscribed: { library.isActivelySubscribed(to: $0) }
            )
            : nil

        List(selection: $selectedEpisodeIDs) {
            // Download Options' Group by Show saves a setting; a failed save
            // reports here beside, never instead of, a download error.
            let downloadErrorMessage = appModel.downloads.lastErrorMessage
            let settingsErrorMessage = appModel.downloadSettings.lastErrorMessage
            if downloadErrorMessage != nil || settingsErrorMessage != nil {
                Section {
                    if let downloadErrorMessage {
                        Label(downloadErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if let settingsErrorMessage {
                        Label(settingsErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !model.downloading.isEmpty {
                Section("Downloading") {
                    ForEach(model.downloading) { item in
                        DownloadingEpisodeRowView(item: item)
                            .disabled(editMode == .active)
                    }
                }
            }

            if !model.failed.isEmpty {
                Section {
                    ForEach(model.failed) { item in
                        FailedDownloadRowView(item: item)
                            .disabled(editMode == .active)
                    }
                } header: {
                    HStack {
                        Text("Failed")
                        Spacer()
                        Button("Retry All", action: retryAllFailedDownloads)
                            .textCase(nil)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                            .disabled(editMode == .active)
                    }
                }
            }

            if let showGroups, !showGroups.isEmpty {
                ForEach(showGroups) { group in
                    Section(isExpanded: expansionBinding(for: group.id)) {
                        ForEach(group.items) { item in
                            downloadedRow(item: item)
                        }
                    } header: {
                        DownloadsShowSectionHeader(
                            group: group,
                            isExpanded: !collapsedShowIDs.contains(group.id),
                            onToggleExpansion: { toggleExpansion(of: group.id) }
                        )
                    }
                }
            } else if !model.downloaded.isEmpty || hasSearchQuery {
                Section("Downloaded") {
                    if hasSearchQuery {
                        if searchSession.isIndexedSearchUnavailable {
                            SearchIndexUpdatingIndicator(mode: searchMode)
                        }
                        EpisodeSearchResultsContent(
                            mode: searchMode,
                            isLoadingVisible: searchSession.isLoadingVisible,
                            isSearching: searchSession.isSearching,
                            results: searchResults,
                            fallbackEpisodes: downloadedEpisodes
                        ) { episode, result in
                            if let item = downloadedItemsByID[episode.episodeID] {
                                downloadedRow(item: item, searchResult: result)
                            }
                        }
                    } else {
                        ForEach(model.downloaded) { item in
                            downloadedRow(item: item)
                        }
                    }
                }
            } else if appModel.downloads.records.isEmpty {
                DownloadsEmptyStateView()
            } else if showsUnplayedOnly && model.downloading.isEmpty && model.failed.isEmpty {
                ContentUnavailableView(
                    "No Unplayed Downloads",
                    systemImage: "checkmark.circle",
                    description: Text("Turn off Unplayed Only to see completed episodes.")
                )
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.horizontal, horizontalSizeClass == .regular ? 32 : nil, for: .scrollContent)
        .navigationTitle("Downloads")
        .toolbarMinimizationBehavior(
            editMode.isEditing || isSearchVisible ? .never : .onScrollDown,
            for: .navigationBar
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass", action: showSearch)
                    .disabled(editMode != .inactive || allDownloads.downloaded.isEmpty)
            }
            .visibilityPriority(.high)

            if !allDownloads.downloaded.isEmpty || editMode == .active {
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    EditButton()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                DownloadsOptionsMenu(
                    showsUnplayedOnly: $showsUnplayedOnly,
                    playedDownloadCount: playedDownloadCount,
                    onRemovePlayed: removePlayedDownloads
                )
                .disabled(editMode == .active)
            }
            .visibilityPriority(.low)

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.downloadStorage) {
                    Label("Storage", systemImage: "internaldrive")
                }
                .disabled(editMode == .active || allDownloads.downloaded.isEmpty)
            }
            .visibilityPriority(.low)

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.downloadSettings) {
                    Label("Download Settings", systemImage: "gear")
                }
                .disabled(editMode == .active)
            }
            .visibilityPriority(.low)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active {
                DownloadsEditActionsView(
                    selectedCount: selectedEpisodeIDs.count,
                    playedDownloadCount: playedDownloadCount,
                    isConfirmingDeleteSelected: $isConfirmingDeleteSelected,
                    isConfirmingRemovePlayed: $isConfirmingEditRemovePlayed,
                    onDeleteSelected: deleteSelectedDownloads,
                    onRemovePlayed: removePlayedDownloads
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .modifier(
            EpisodeSearchPresentationModifier(
                isSearchVisible: isSearchVisible,
                prompt: "Downloaded episodes",
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
        .onChange(of: editMode) { _, mode in
            if mode == .active {
                hideSearch()
            } else {
                selectedEpisodeIDs.removeAll()
            }
        }
        .onChange(of: allDownloads.downloaded.isEmpty) { _, isEmpty in
            if isEmpty {
                editMode = .inactive
            }
        }
        .onChange(of: showsUnplayedOnly) { _, _ in
            synchronizeSelectionWithFilter()
        }
        .task(id: searchTaskKey) {
            let library = appModel.library
            // Downloads survive an unsubscribe as orphans, but the derived
            // index is scoped to active podcasts and their cache rows; feed
            // orphans to the session so they stay findable in this list.
            let orphanedEpisodes = downloadedEpisodes.filter {
                !library.isActivelySubscribed(to: $0.podcastID)
            }
            await searchSession.update(
                episodes: downloadedEpisodes,
                query: searchQuery,
                mode: searchMode,
                unindexedEpisodes: orphanedEpisodes,
                indexedSearchProvider: {
                    await library.searchEpisodes(
                        query: searchQuery,
                        mode: searchMode,
                        allowedEpisodeIDs: Set(
                            downloadedEpisodes.map(\.episodeID)
                        )
                    )
                },
                showNotesProvider: { await library.showNotesHTMLByEpisodeID() }
            )
        }
        .animation(reduceMotion ? nil : .default, value: model.animationKey)
        .animation(reduceMotion ? nil : .default, value: grouping)
        .sensoryFeedback(.success, trigger: allDownloads.downloaded.count) { oldCount, newCount in
            newCount > oldCount
        }
        .environment(\.editMode, $editMode)
    }

    private var hasSearchQuery: Bool {
        EpisodeSearch.isSearchActive(query: searchQuery)
    }

    private var playedDownloadCount: Int {
        appModel.downloads.records.count { record in
            record.state == .completed && appModel.library.progressRecord(for: record.episodeID)?.isPlayed == true
        }
    }

    @ViewBuilder
    private func downloadedRow(
        item: DownloadListItem,
        searchResult: EpisodeSearchResult? = nil
    ) -> some View {
        if editMode == .active {
            DownloadSelectionRowView(item: item, searchResult: searchResult)
        } else {
            DownloadedEpisodeRowButton(
                item: item,
                searchResult: searchResult,
                onSelect: dismissSearchKeyboard,
                onOpenEpisode: onOpenEpisode
            )
        }
    }

    /// A thin adapter: `Section(isExpanded:)` takes a binding, and the
    /// session's collapsed set is the one source of truth.
    private func expansionBinding(for podcastID: String) -> Binding<Bool> {
        Binding {
            !collapsedShowIDs.contains(podcastID)
        } set: { isExpanded in
            if isExpanded {
                collapsedShowIDs.remove(podcastID)
            } else {
                collapsedShowIDs.insert(podcastID)
            }
        }
    }

    private func toggleExpansion(of podcastID: String) {
        withAnimation(reduceMotion ? nil : .default) {
            expansionBinding(for: podcastID).wrappedValue.toggle()
        }
    }

    private func retryAllFailedDownloads() {
        appModel.downloads.retryAllFailedDownloads(modelContext: modelContext)
    }

    private func showSearch() {
        editMode = .inactive
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

    private func deleteSelectedDownloads() {
        let selectedRecords = appModel.downloads.records.filter {
            $0.state == .completed && selectedEpisodeIDs.contains($0.episodeID)
        }
        appModel.deleteDownloads(selectedRecords, modelContext: modelContext)
        selectedEpisodeIDs.removeAll()
        editMode = .inactive
    }

    private func removePlayedDownloads() {
        appModel.deletePlayedDownloads(modelContext: modelContext)
        selectedEpisodeIDs.formIntersection(Set(appModel.downloads.records.map(\.episodeID)))
    }

    private func synchronizeSelectionWithFilter() {
        let selectableEpisodeIDs: [String] = appModel.downloads.records.compactMap { record in
            guard record.state == .completed else {
                return nil
            }
            guard !showsUnplayedOnly || appModel.library.progressRecord(for: record.episodeID)?.isPlayed != true else {
                return nil
            }
            return record.episodeID
        }
        selectedEpisodeIDs.formIntersection(Set(selectableEpisodeIDs))
    }
}
