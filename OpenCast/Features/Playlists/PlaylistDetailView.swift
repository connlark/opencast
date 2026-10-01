import SwiftData
import SwiftUI

/// One playlist. A smart playlist hands off to `SmartPlaylistDetailView`. A
/// manual playlist shows the hero with Play and Shuffle, then its episodes in
/// the listener's order. Tapping a row plays from there. Items whose episode
/// no longer resolves stay in place as unavailable rows until removed.
struct PlaylistDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var editMode: EditMode = .inactive

    let playlistID: String
    var onOpenEpisode: (String) -> Void = { _ in }

    private var summary: PlaylistSummary? {
        appModel.playlists.playlists.first { $0.playlistID == playlistID }
    }

    var body: some View {
        if let summary, summary.kind == .smart {
            SmartPlaylistDetailView(summary: summary, onOpenEpisode: onOpenEpisode)
        } else {
            manualBody
        }
    }

    @ViewBuilder
    private var manualBody: some View {
        let summary = self.summary
        let allItems = appModel.playlists.resolvedItems(in: playlistID) { appModel.episodeSnapshot(for: $0) }
        let visibleItems = summary?.hidesPlayed == true
            ? allItems.filter { !isPlayed($0.item.episodeID) }
            : allItems
        let canPlay = allItems.contains { $0.isResolved && !isPlayed($0.item.episodeID) }
        // Play Next and Play Last skip the episode now playing.
        let currentEpisodeID = appModel.playback.currentEpisode?.id.rawValue
        let canEnqueue = allItems.contains {
            $0.isResolved && $0.item.episodeID != currentEpisodeID && !isPlayed($0.item.episodeID)
        }
        let canDownloadAll = appModel.hasPlaylistDownloadAllCandidates(playlistID)

        Group {
            if let summary {
                playlistList(summary: summary, allItems: allItems, visibleItems: visibleItems, canPlay: canPlay)
            } else {
                ContentUnavailableView("Playlist Unavailable", systemImage: "music.note.list")
            }
        }
        .navigationTitle(summary?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary {
                ToolbarItem(placement: .primaryAction) {
                    PlaylistActionsMenu(
                        summary: summary,
                        canEdit: !visibleItems.isEmpty,
                        canEnqueue: canEnqueue,
                        canDownloadAll: canDownloadAll,
                        editMode: $editMode
                    )
                }
            }
        }
        .environment(\.editMode, $editMode)
    }

    private func playlistList(
        summary: PlaylistSummary,
        allItems: [PlaylistResolvedItem],
        visibleItems: [PlaylistResolvedItem],
        canPlay: Bool
    ) -> some View {
        let counts = appModel.playlists.counts(for: playlistID) { isPlayed($0) }

        return List {
            Section {
                PlaylistHeroHeader(
                    summary: summary,
                    itemCount: summary.itemCount,
                    totalDuration: summary.totalDuration,
                    counts: counts,
                    sources: coverSources(for: summary),
                    primaryAction: PlaylistPrimaryAction.resolve(items: allItems, library: appModel.library),
                    canPlay: canPlay,
                    onPlay: play,
                    onShuffle: shuffle
                )
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if allItems.isEmpty {
                    ContentUnavailableView(
                        "No Episodes",
                        systemImage: "music.note.list",
                        description: Text("Add episodes from any episode menu.")
                    )
                } else if visibleItems.isEmpty {
                    ContentUnavailableView(
                        "No Unplayed Episodes",
                        systemImage: "eye.slash",
                        description: Text("Played episodes are hidden. Turn off Hide Played to see them.")
                    )
                } else {
                    ForEach(visibleItems) { resolvedItem in
                        row(for: resolvedItem)
                            .modifier(
                                PlaylistRowActionsModifier {
                                    removeItems(withIDs: [resolvedItem.id])
                                }
                            )
                    }
                    .onMove { source, destination in
                        moveItems(
                            fromOffsets: source,
                            toOffset: destination,
                            visibleItems: visibleItems,
                            allItems: allItems
                        )
                    }
                    .onDelete { offsets in
                        removeItems(atOffsets: offsets, visibleItems: visibleItems)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            EpisodeArtworkGlowBackground(preview: glowPreview(for: summary, items: allItems))
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .animation(listAnimation, value: summary.hidesPlayed)
    }

    @ViewBuilder
    private func row(for resolvedItem: PlaylistResolvedItem) -> some View {
        if let snapshot = resolvedItem.snapshot {
            PlaylistEpisodeRowView(
                itemID: resolvedItem.id,
                playlistID: playlistID,
                episode: snapshot,
                onOpenEpisode: onOpenEpisode
            )
        } else {
            PlaylistUnavailableRowView(item: resolvedItem.item)
        }
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private func isPlayed(_ episodeID: String) -> Bool {
        appModel.library.progressRecord(for: episodeID)?.isPlayed == true
    }

    private func coverSources(for summary: PlaylistSummary) -> PlaylistCoverSources {
        PlaylistCoverSources.make(
            summary: summary,
            items: appModel.playlists.itemsByPlaylistID[playlistID] ?? []
        ) { podcastID in
            appModel.library.podcastCache(for: podcastID)?.artworkURL.flatMap(URL.init(string:))
        }
    }

    /// The glow blurs one decoded preview rather than the whole mosaic: the
    /// first cover show's, falling back to one of its resolved episodes' so
    /// shows no longer in the library still glow, as they still draw in the
    /// mosaic. With none, the screen keeps its plain background.
    private func glowPreview(for summary: PlaylistSummary, items: [PlaylistResolvedItem]) -> ArtworkPreview? {
        for podcastID in summary.coverPodcastIDs {
            if let podcast = appModel.library.podcastCache(for: podcastID),
               let preview = appModel.library.artworkPreview(for: podcast) {
                return preview
            }
            for resolvedItem in items where resolvedItem.item.podcastID == podcastID {
                if let snapshot = resolvedItem.snapshot,
                   let preview = appModel.library.artworkPreview(for: snapshot) {
                    return preview
                }
            }
        }
        return nil
    }

    private func play(_ mode: PlaylistPlayMode) {
        appModel.playPlaylist(playlistID, mode: mode, shuffle: false, modelContext: modelContext)
    }

    private func shuffle(_ mode: PlaylistPlayMode) {
        appModel.playPlaylist(playlistID, mode: mode, shuffle: true, modelContext: modelContext)
    }

    /// Hide Played can leave gaps in the visible rows, so the move is
    /// translated to the full item order the store keeps.
    private func moveItems(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        visibleItems: [PlaylistResolvedItem],
        allItems: [PlaylistResolvedItem]
    ) {
        let offsets = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: visibleItems.map(\.id),
            allItemIDs: allItems.map(\.id),
            fromOffsets: source,
            toOffset: destination
        )
        guard !offsets.fromOffsets.isEmpty else {
            return
        }
        appModel.performPlaylistMutation {
            appModel.playlists.move(
                fromOffsets: offsets.fromOffsets,
                toOffset: offsets.toOffset,
                in: playlistID,
                modelContext: modelContext
            )
        }
    }

    private func removeItems(atOffsets offsets: IndexSet, visibleItems: [PlaylistResolvedItem]) {
        let itemIDs = offsets.compactMap { index in
            visibleItems.indices.contains(index) ? visibleItems[index].id : nil
        }
        removeItems(withIDs: Set(itemIDs))
    }

    private func removeItems(withIDs itemIDs: Set<String>) {
        appModel.performPlaylistMutation {
            appModel.playlists.remove(itemIDs: itemIDs, from: playlistID, modelContext: modelContext)
        }
    }
}
