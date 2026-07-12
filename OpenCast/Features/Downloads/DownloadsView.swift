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
    @State private var isConfirmingMenuRemovePlayed = false
    @State private var isConfirmingEditRemovePlayed = false

    let onOpenEpisode: (String) -> Void
    var selectsEpisodeDetailOnPlay = false

    var body: some View {
        let allDownloads = DownloadsListModel.make(
            records: appModel.downloads.records,
            library: appModel.library,
            showsUnplayedOnly: false
        )
        let model = showsUnplayedOnly
            ? DownloadsListModel.make(
                records: appModel.downloads.records,
                library: appModel.library,
                showsUnplayedOnly: true
            )
            : allDownloads
        let downloadedEpisodes = model.downloaded.map(\.episode)
        let downloadedItemsByID = Dictionary(
            uniqueKeysWithValues: model.downloaded.map { ($0.id, $0) }
        )
        let searchTaskKey = EpisodeSearchRequestKey(
            episodes: downloadedEpisodes,
            query: searchQuery,
            mode: searchMode
        )
        let searchResults = searchSession.displayedResults(for: searchTaskKey)

        List(selection: $selectedEpisodeIDs) {
            Section("Storage") {
                DownloadsStorageSummaryView(
                    breakdowns: DownloadsPodcastBreakdown.make(items: allDownloads.downloaded)
                )
                .disabled(editMode == .active)
            }

            if let downloadErrorMessage = appModel.downloads.lastErrorMessage {
                Section {
                    Label(downloadErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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

            if !model.downloaded.isEmpty || hasSearchQuery {
                Section("Downloaded") {
                    if hasSearchQuery {
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass", action: showSearch)
                    .disabled(editMode != .inactive || allDownloads.downloaded.isEmpty)

                if !allDownloads.downloaded.isEmpty || editMode == .active {
                    EditButton()
                }

                Menu {
                    Toggle(isOn: $showsUnplayedOnly) {
                        Label("Unplayed Only", systemImage: "circle")
                    }

                    Button(
                        "Remove Played",
                        systemImage: "checkmark.circle",
                        role: .destructive,
                        action: confirmMenuRemovePlayed
                    )
                    .disabled(playedDownloadCount == 0)
                } label: {
                    Label("Download Options", systemImage: "ellipsis.circle")
                }
                .disabled(editMode == .active)
                .confirmationDialog(
                    "Remove played downloads?",
                    isPresented: $isConfirmingMenuRemovePlayed,
                    titleVisibility: .visible
                ) {
                    Button("Remove Played", role: .destructive, action: removePlayedDownloads)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Played downloads that aren’t currently in use will be removed from this device.")
                }
            }

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
                searchMode: $searchMode
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
            await searchSession.update(
                episodes: downloadedEpisodes,
                query: searchQuery,
                mode: searchMode,
                showNotesProvider: { await library.showNotesHTMLByEpisodeID() }
            )
        }
        .animation(reduceMotion ? nil : .default, value: model.animationKey)
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
                onOpenEpisode: onOpenEpisode,
                selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay
            )
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

    private func confirmMenuRemovePlayed() {
        isConfirmingMenuRemovePlayed = true
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
