import SwiftUI

/// One proposed playlist: its editable name and options in the header, its
/// episodes as removable, reorderable rows, and the model's reason in the
/// footer. Every edit writes through to the sheet's draft.
struct PlaylistProposalSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var draft: PlaylistProposalDraft
    /// The proposal's 1-based position. It scopes the identifiers, because
    /// one episode can sit in two proposals.
    let number: Int
    let onRemovePlaylist: () -> Void
    let onAddEpisodes: () -> Void

    var body: some View {
        Section {
            ForEach(draft.episodes) { episode in
                EpisodeRowView(episode: episode)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("playlist-proposal-\(number)-episode-\(episode.episodeID)")
                    .modifier(
                        PlaylistRowActionsModifier {
                            removeEpisode(withID: episode.episodeID)
                        }
                    )
            }
            .onMove(perform: moveEpisodes)
            .onDelete(perform: removeEpisodes)

            Button(PlaylistOrganizerCopy.addEpisodes, systemImage: "plus.circle", action: onAddEpisodes)
                .accessibilityIdentifier("playlist-proposal-\(number)-add")
        } header: {
            header
        } footer: {
            if !draft.rationale.isEmpty {
                Text(draft.rationale)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField(PlaylistOrganizerCopy.proposalTitlePlaceholder, text: $draft.title)
                .bold()
                .foregroundStyle(Color.primary)
                .submitLabel(.done)
                .accessibilityIdentifier("playlist-proposal-\(number)-title")

            Menu {
                Button(PlaylistItemSortOrder.oldestFirst.title, action: sortOldestFirst)
                Button(PlaylistItemSortOrder.newestFirst.title, action: sortNewestFirst)
                Divider()
                Button(
                    PlaylistOrganizerCopy.removePlaylist,
                    systemImage: "trash",
                    role: .destructive,
                    action: onRemovePlaylist
                )
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("playlist-proposal-\(number)-options")
        }
        .font(.title3)
        // Section headers style their text as secondary captions; the name
        // has to read as an editable title. The label style sits outside the
        // Menu because setting it inside a Menu's label closure crashes on
        // iOS 27.
        .textCase(nil)
        .labelStyle(.iconOnly)
    }

    private func sortOldestFirst() {
        sort(by: .oldestFirst)
    }

    private func sortNewestFirst() {
        sort(by: .newestFirst)
    }

    private func sort(by order: PlaylistItemSortOrder) {
        withAnimation(reduceMotion ? nil : .default) {
            draft.episodes = order.sorted(draft.episodes, date: \.publishedAt)
        }
    }

    private func moveEpisodes(fromOffsets source: IndexSet, toOffset destination: Int) {
        draft.episodes.move(fromOffsets: source, toOffset: destination)
    }

    private func removeEpisodes(atOffsets offsets: IndexSet) {
        draft.episodes.remove(atOffsets: offsets)
    }

    private func removeEpisode(withID episodeID: String) {
        draft.episodes.removeAll { $0.episodeID == episodeID }
    }
}
