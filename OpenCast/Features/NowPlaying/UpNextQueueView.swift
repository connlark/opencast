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
                    }
                }
            }
            .navigationTitle("Up Next")
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
            isPresented: alertBinding,
            presenting: activeAlert
        ) { _ in
            Button("OK", role: .cancel) {
                activeAlert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { activeAlert = nil } }
        )
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
