import SwiftUI

/// More of the show's episodes for one proposal. The episodes not already in
/// it are ranked against the search text, which starts as the proposal's
/// name; taps collect episodes in order, and Done appends them.
struct PlaylistProposalAddEpisodesView: View {
    private static let candidateLimit = 30
    private static let queryDebounce = Duration.milliseconds(150)

    private struct RankingKey: Equatable {
        var query: String
        var isCatalogResolved: Bool
    }

    @Environment(\.dismiss) private var dismiss

    let request: PlaylistProposalAddEpisodesRequest
    let show: PlaylistOrganizerShow
    /// Builds the show's catalog on first use and keeps it for the sheet.
    let loadCatalog: @MainActor () async -> PlaylistOrganizerCatalog?
    let onDone: ([EpisodeListItemSnapshot]) -> Void

    @State private var query: String
    @State private var catalog: PlaylistOrganizerCatalog?
    @State private var isCatalogResolved = false
    @State private var candidates: [EpisodeListItemSnapshot]?
    @State private var chosenEpisodeIDs: [String] = []

    init(
        request: PlaylistProposalAddEpisodesRequest,
        show: PlaylistOrganizerShow,
        loadCatalog: @escaping @MainActor () async -> PlaylistOrganizerCatalog?,
        onDone: @escaping ([EpisodeListItemSnapshot]) -> Void
    ) {
        self.request = request
        self.show = show
        self.loadCatalog = loadCatalog
        self.onDone = onDone
        _query = State(initialValue: request.query)
    }

    var body: some View {
        List(candidates ?? []) { episode in
            row(for: episode)
        }
        .overlay {
            if candidates == nil {
                ProgressView()
            } else if candidates?.isEmpty == true {
                ContentUnavailableView.search(text: query)
            }
        }
        .accessibilityIdentifier("Playlist Proposal Add Episodes")
        .navigationTitle("Add Episodes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: finish)
            }
        }
        // The catalog loads for the view's lifetime; keyed on the query it
        // would restart from the first line on every keystroke.
        .task {
            await resolveCatalog()
        }
        .task(id: RankingKey(query: query, isCatalogResolved: isCatalogResolved)) {
            await rank()
        }
    }

    private func row(for episode: EpisodeListItemSnapshot) -> some View {
        let isChosen = chosenEpisodeIDs.contains(episode.episodeID)
        return Button {
            toggle(episode)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                    if let publishedAt = episode.publishedAt {
                        Text(publishedAt, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isChosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("playlist-proposal-add-\(episode.episodeID)")
    }

    private func resolveCatalog() async {
        let loaded = await loadCatalog()
        guard !Task.isCancelled else {
            return
        }
        catalog = loaded
        isCatalogResolved = true
    }

    private func rank() async {
        guard isCatalogResolved else {
            return
        }
        do {
            try await Task.sleep(for: Self.queryDebounce)
        } catch is CancellationError {
            return
        } catch {
            return
        }
        let positions: [Int]
        if let catalog {
            positions = await catalog.additions(
                for: query,
                excluding: request.excludedPositions,
                limit: Self.candidateLimit
            )
        } else {
            // Without a catalog the list falls back to the newest episodes.
            positions = Array(
                show.episodes.indices
                    .lazy
                    .filter { !request.excludedPositions.contains($0) }
                    .prefix(Self.candidateLimit)
            )
        }
        guard !Task.isCancelled else {
            return
        }
        candidates = positions.compactMap(show.snapshot(atPosition:))
    }

    private func toggle(_ episode: EpisodeListItemSnapshot) {
        if let index = chosenEpisodeIDs.firstIndex(of: episode.episodeID) {
            chosenEpisodeIDs.remove(at: index)
        } else {
            chosenEpisodeIDs.append(episode.episodeID)
        }
    }

    private func finish() {
        onDone(chosenEpisodeIDs.compactMap { show.snapshotsByEpisodeID[$0] })
        dismiss()
    }
}
