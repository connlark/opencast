import SwiftData
import SwiftUI

/// Files one episode into manual playlists. Each row toggles membership as
/// it is tapped, so the sheet only needs Done.
struct AddToPlaylistSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let episodeID: String

    @State private var namePrompt: PlaylistNamePromptRequest?
    // The root's playlist alert cannot present over this sheet, so failures
    // raised here surface on the sheet itself.
    @State private var errorMessage: String?
    // Every toggle bumps the playlist's updatedAt; freezing the order at the
    // first change keeps rows from jumping under the listener's finger.
    @State private var pinnedPlaylistOrder: [String]?
    @State private var selectionFeedbackTrigger = 0

    var body: some View {
        NavigationStack {
            Group {
                if let episode = appModel.episodeSnapshot(for: episodeID) {
                    playlistList(episode: episodeForPlaylist(episode))
                } else {
                    ContentUnavailableView("Episode Unavailable", systemImage: "music.note.list")
                }
            }
            .accessibilityIdentifier("Add to Playlist Sheet")
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .playlistNamePrompt($namePrompt, onCommit: createPlaylist)
        }
        .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
        .alert("Playlist Error", item: $errorMessage) { _ in
        } message: { message in
            Text(message)
        }
    }

    private func playlistList(episode: EpisodeListItemSnapshot) -> some View {
        let memberIDs = appModel.playlists.playlistIDs(containing: episode.episodeID)

        return List {
            Section {
                AddToPlaylistNewRow(action: promptNewPlaylist)
                ForEach(orderedManualPlaylists) { summary in
                    let isMember = memberIDs.contains(summary.playlistID)
                    AddToPlaylistRow(
                        summary: summary,
                        sources: coverSources(for: summary),
                        isSelected: isMember
                    ) {
                        toggle(summary, episode: episode, isMember: isMember)
                    }
                }
            } header: {
                episodeHeader(episode, playlistCount: memberIDs.count)
            } footer: {
                Text("Smart playlists fill themselves, so they aren’t listed here.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func episodeHeader(_ episode: EpisodeListItemSnapshot, playlistCount: Int) -> some View {
        HStack(spacing: 12) {
            ArtworkPlaceholder(
                title: episode.podcastTitle,
                imageURL: episode.artworkURL,
                size: 64,
                cacheKind: .episode,
                preview: headerArtworkPreview(for: episode)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(episode.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if playlistCount >= 1 {
                    Text("In ^[\(playlistCount) playlist](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textCase(nil)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    /// Manual playlists, most recently updated first, until the first change
    /// pins the order; playlists created after that lead the list.
    private var orderedManualPlaylists: [PlaylistSummary] {
        let manualPlaylists = appModel.playlists.playlists
            .filter { $0.kind == .manual }
            .sorted(by: Self.isMoreRecentlyUpdated)
        guard let pinnedPlaylistOrder else {
            return manualPlaylists
        }
        let pinnedRank = Dictionary(
            pinnedPlaylistOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let newPlaylists = manualPlaylists.filter { pinnedRank[$0.playlistID] == nil }
        let pinnedPlaylists = manualPlaylists
            .filter { pinnedRank[$0.playlistID] != nil }
            .sorted { (pinnedRank[$0.playlistID] ?? 0) < (pinnedRank[$1.playlistID] ?? 0) }
        return newPlaylists + pinnedPlaylists
    }

    private static func isMoreRecentlyUpdated(_ lhs: PlaylistSummary, _ rhs: PlaylistSummary) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.playlistID < rhs.playlistID
    }

    private func coverSources(for summary: PlaylistSummary) -> PlaylistCoverSources {
        PlaylistCoverSources.make(
            summary: summary,
            items: appModel.playlists.itemsByPlaylistID[summary.playlistID] ?? []
        ) { podcastID in
            appModel.library.podcastCache(for: podcastID)?.artworkURL.flatMap(URL.init(string:))
        }
    }

    private func headerArtworkPreview(for episode: EpisodeListItemSnapshot) -> ArtworkPreview? {
        if let preview = appModel.library.artworkPreview(for: episode) {
            return preview
        }
        return appModel.library.podcastCache(for: episode.podcastID).flatMap { podcast in
            appModel.library.artworkPreview(for: podcast)
        }
    }

    private func episodeForPlaylist(_ episode: EpisodeListItemSnapshot) -> EpisodeListItemSnapshot {
        PlaylistEpisodeArtworkFallback.episode(
            episode,
            showArtworkURL: appModel.library.podcastCache(for: episode.podcastID)?.artworkURL
        )
    }

    private func toggle(_ summary: PlaylistSummary, episode: EpisodeListItemSnapshot, isMember: Bool) {
        pinPlaylistOrderIfNeeded()
        let didChange: Bool
        if isMember {
            let itemIDs = Set(
                (appModel.playlists.itemsByPlaylistID[summary.playlistID] ?? [])
                    .filter { $0.episodeID == episode.episodeID }
                    .map(\.itemID)
            )
            didChange = performMutation {
                appModel.playlists.remove(itemIDs: itemIDs, from: summary.playlistID, modelContext: modelContext)
            }
        } else {
            let addedCount = performMutation {
                appModel.playlists.add([episode], to: summary.playlistID, modelContext: modelContext)
            }
            didChange = addedCount > 0
        }
        if didChange {
            selectionFeedbackTrigger += 1
        }
    }

    private func promptNewPlaylist() {
        namePrompt = .create()
    }

    private func createPlaylist(_ request: PlaylistNamePromptRequest, named name: String) {
        guard let episode = appModel.episodeSnapshot(for: episodeID).map(episodeForPlaylist) else {
            return
        }
        pinPlaylistOrderIfNeeded()
        let summary = performMutation {
            appModel.playlists.create(name: name, kind: .manual, modelContext: modelContext)
        }
        guard let summary else {
            return
        }
        let addedCount = performMutation {
            appModel.playlists.add([episode], to: summary.playlistID, modelContext: modelContext)
        }
        if addedCount > 0 {
            selectionFeedbackTrigger += 1
        }
    }

    private func pinPlaylistOrderIfNeeded() {
        guard pinnedPlaylistOrder == nil else {
            return
        }
        pinnedPlaylistOrder = orderedManualPlaylists.map(\.playlistID)
    }

    private func performMutation<Value>(_ mutation: () -> Value) -> Value {
        let value = mutation()
        if let message = appModel.playlists.consumeLastErrorMessage() {
            errorMessage = message
        }
        return value
    }
}
