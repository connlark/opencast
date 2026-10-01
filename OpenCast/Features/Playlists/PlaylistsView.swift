import SwiftData
import SwiftUI

/// Every playlist, as a grid of covers or a list of rows. It follows the
/// Library's stored layout, except that Automatic always means the grid
/// here: covers are how playlists are told apart. A new smart playlist opens
/// through `onOpenPlaylist` once its name prompt has dismissed; a new manual
/// one stays on the collection.
struct PlaylistsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var namePromptRequest: PlaylistNamePromptRequest?
    @State private var pendingOpenPlaylistID: String?
    @State private var selectionFeedbackTrigger = 0

    var onOpenPlaylist: (String) -> Void = { _ in }

    private var layout: LibraryLayout {
        appModel.libraryDisplaySettings.layout == .list ? .list : .grid
    }

    var body: some View {
        let playlists = appModel.playlists.playlists

        content(playlists: playlists)
            .animation(reduceMotion ? nil : .default, value: playlists.map(\.id))
            .animation(reduceMotion ? nil : .default, value: layout)
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsErrorBanner(message: appModel.playlistDisplaySettings.lastErrorMessage)
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.large)
            .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
            .toolbar {
                if !playlists.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        optionsMenu
                    }
                    .visibilityPriority(.low)
                }

                ToolbarItem(placement: .topBarPinnedTrailing) {
                    addMenu
                }
            }
            .playlistNamePrompt($namePromptRequest, onCommit: commitName)
            .onChange(of: namePromptRequest) {
                openPendingPlaylistAfterPrompt()
            }
            .onChange(of: pendingOpenPlaylistID) {
                openPendingPlaylistAfterPrompt()
            }
            .onAppear(perform: appModel.library.advanceNewEpisodeReferenceDate)
    }

    @ViewBuilder
    private func content(playlists: [PlaylistSummary]) -> some View {
        if playlists.isEmpty {
            ContentUnavailableView {
                Label("No Playlists", systemImage: "music.note.list")
            } description: {
                Text("Make a playlist, then add episodes from any episode menu.")
            } actions: {
                Button("New Playlist…", action: promptNewPlaylist)
                    .buttonStyle(.glassProminent)
            }
        } else if layout == .grid {
            grid(playlists: playlists)
                .transition(.opacity)
        } else {
            List {
                ForEach(playlists) { summary in
                    PlaylistRowView(summary: summary, sources: coverSources(for: summary))
                        .modifier(
                            PlaylistCollectionActionsModifier(
                                summary: summary,
                                supportsSwipeActions: true,
                                onRename: requestRename
                            )
                        )
                }
            }
            .accessibilityIdentifier("Playlists List")
            .transition(.opacity)
        }
    }

    private func grid(playlists: [PlaylistSummary]) -> some View {
        // Reads the width in the same layout pass, so the first frame
        // already has its final column count.
        GeometryReader { proxy in
            let metrics = LibraryGridMetrics.resolve(
                containerWidth: proxy.size.width,
                isCompact: horizontalSizeClass == .compact || verticalSizeClass == .compact,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )

            ScrollView {
                LazyVGrid(columns: metrics.columns, spacing: metrics.rowSpacing) {
                    ForEach(playlists) { summary in
                        PlaylistTileView(summary: summary, sources: coverSources(for: summary), metrics: metrics)
                            .modifier(
                                PlaylistCollectionActionsModifier(
                                    summary: summary,
                                    supportsSwipeActions: false,
                                    onRename: requestRename
                                )
                            )
                    }
                }
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("Playlists Grid")
            .contentMargins(.horizontal, metrics.horizontalMargin, for: .scrollContent)
            .contentMargins(.bottom, 72, for: .scrollContent)
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New Playlist…", systemImage: "text.badge.plus", action: promptNewPlaylist)
                .accessibilityIdentifier("New Playlist")
            Button("New Smart Playlist…", systemImage: "sparkles", action: promptNewSmartPlaylist)
                .accessibilityIdentifier("New Smart Playlist")
        } label: {
            Label("Add", systemImage: "plus")
        }
        .accessibilityIdentifier("Playlists Add Menu")
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: sortOrderBinding) {
                ForEach(PlaylistSortOrder.allCases) { sortOrder in
                    Text(sortOrder.title)
                        .tag(sortOrder)
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
        } label: {
            Label("Playlist Options", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("Playlist Options")
        // Keyed to user picks, not the stored value, so loading the stored
        // order at launch stays silent.
        .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
    }

    private var sortOrderBinding: Binding<PlaylistSortOrder> {
        Binding {
            appModel.playlistDisplaySettings.sortOrder
        } set: { sortOrder in
            guard sortOrder != appModel.playlistDisplaySettings.sortOrder,
                  appModel.setPlaylistSortOrder(sortOrder, modelContext: modelContext)
            else {
                return
            }
            selectionFeedbackTrigger += 1
        }
    }

    private func coverSources(for summary: PlaylistSummary) -> PlaylistCoverSources {
        PlaylistCoverSources.make(
            summary: summary,
            items: appModel.playlists.itemsByPlaylistID[summary.playlistID] ?? [],
            podcastArtworkURL: podcastArtworkURL
        )
    }

    private func podcastArtworkURL(for podcastID: String) -> URL? {
        appModel.library.podcastCache(for: podcastID)?.artworkURL.flatMap(URL.init(string:))
    }

    private func promptNewPlaylist() {
        namePromptRequest = PlaylistNamePromptRequest.create()
    }

    private func promptNewSmartPlaylist() {
        namePromptRequest = PlaylistNamePromptRequest.createSmart()
    }

    private func requestRename(_ summary: PlaylistSummary) {
        namePromptRequest = PlaylistNamePromptRequest.rename(summary)
    }

    private func commitName(_ request: PlaylistNamePromptRequest, name: String) {
        switch request.kind {
        case .create:
            appModel.performPlaylistMutation {
                appModel.playlists.create(name: name, kind: .manual, modelContext: modelContext)
            }
        case .createSmart:
            let summary = appModel.performPlaylistMutation {
                appModel.playlists.create(name: name, kind: .smart, modelContext: modelContext)
            }
            pendingOpenPlaylistID = summary?.playlistID
        case .rename(let playlistID):
            appModel.renamePlaylist(playlistID, to: name, modelContext: modelContext)
        }
    }

    /// Pushing from the alert's own action would race its dismissal, so the
    /// new smart playlist opens once the prompt's request has cleared. Both
    /// orders of the two state changes end here.
    private func openPendingPlaylistAfterPrompt() {
        guard namePromptRequest == nil, let playlistID = pendingOpenPlaylistID else {
            return
        }
        pendingOpenPlaylistID = nil
        onOpenPlaylist(playlistID)
    }
}
