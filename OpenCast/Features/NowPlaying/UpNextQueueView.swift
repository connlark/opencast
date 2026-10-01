import SwiftData
import SwiftUI

struct UpNextQueueView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showsClearConfirmation = false
    @State private var activeAlert: UpNextQueueAlert?

    var body: some View {
        let episodes = resolvedEpisodes()
        let playlistSource = appModel.currentPlaylistSource
        let playlistRemainingCount = playlistSource.map {
            appModel.remainingQueuedCount(forPlaylist: $0.playlistID)
        } ?? 0

        NavigationStack {
            Group {
                if episodes.isEmpty {
                    ContentUnavailableView(
                        "Nothing Up Next",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text("Episodes you queue will appear here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(episodes) { episode in
                                UpNextQueueRowButton(episode: episode) {
                                    play(episode)
                                }
                            }
                            .onMove { source, destination in
                                moveItems(
                                    fromOffsets: source,
                                    toOffset: destination,
                                    episodes: episodes
                                )
                            }
                            .onDelete { offsets in
                                removeItems(atOffsets: offsets, episodes: episodes)
                            }
                        } footer: {
                            if let playlistSource, playlistRemainingCount >= 1 {
                                Text(PlaylistPlaybackSourceText.upNextFooter(name: playlistSource.name))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Up Next")
            // An empty subtitle takes no space under the large title.
            .navigationSubtitle(
                playlistSource.map {
                    PlaylistPlaybackSourceText.upNextSubtitle(
                        name: $0.name,
                        remainingCount: playlistRemainingCount
                    )
                } ?? ""
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .disabled(episodes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        showsClearConfirmation = true
                    }
                    .disabled(episodes.isEmpty)
                    .confirmationDialog(
                        "Clear Up Next?",
                        isPresented: $showsClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Up Next", role: .destructive, action: clear)
                    }
                }
            }
        }
        .alert(
            activeAlert?.title ?? "Up Next Error",
            item: $activeAlert
        ) { _ in
        } message: { alert in
            Text(alert.message)
        }
    }

    private func resolvedEpisodes() -> [EpisodeListItemSnapshot] {
        appModel.upNextQueue.items.compactMap { appModel.episodeSnapshot(for: $0.episodeID) }
    }

    private func play(_ episode: EpisodeListItemSnapshot) {
        do {
            try appModel.playEpisode(
                episode,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
            dismiss()
        } catch {
            activeAlert = .playback(error.localizedDescription)
        }
    }

    private func moveItems(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        episodes: [EpisodeListItemSnapshot]
    ) {
        var reorderedEpisodes = episodes
        reorderedEpisodes.move(fromOffsets: source, toOffset: destination)
        performQueueMutation {
            appModel.upNextQueue.reorderVisibleEpisodeIDs(
                reorderedEpisodes.map(\.episodeID),
                modelContext: modelContext
            )
        }
    }

    private func removeItems(
        atOffsets offsets: IndexSet,
        episodes: [EpisodeListItemSnapshot]
    ) {
        let episodeIDs = offsets.compactMap { index in
            episodes.indices.contains(index) ? episodes[index].episodeID : nil
        }
        performQueueMutation {
            appModel.upNextQueue.remove(
                episodeIDs: Set(episodeIDs),
                modelContext: modelContext
            )
        }
    }

    private func clear() {
        performQueueMutation {
            appModel.upNextQueue.clear(modelContext: modelContext)
        }
    }

    private func performQueueMutation(_ mutation: () -> Bool) {
        guard !mutation() else {
            return
        }
        let message = appModel.upNextQueue.consumeLastErrorMessage()
            ?? "Up Next could not be updated."
        activeAlert = .queue(message)
    }
}
