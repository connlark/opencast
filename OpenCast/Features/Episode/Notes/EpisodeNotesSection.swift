import SwiftData
import SwiftUI

/// The Private Notes cards on episode detail; hidden while the episode has none.
struct EpisodeNotesSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var actions = EpisodeNotesActions()
    @Query private var notes: [EpisodeNoteRecord]
    let episodeTitle: String
    let showTitle: String
    let onSeek: (TimeInterval) -> Void

    init(episodeID: String, episodeTitle: String, showTitle: String, onSeek: @escaping (TimeInterval) -> Void) {
        _notes = Query(EpisodeNoteStore.notes(for: episodeID))
        self.episodeTitle = episodeTitle
        self.showTitle = showTitle
        self.onSeek = onSeek
    }

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Private Notes")
                        .font(.headline)
                    Spacer()
                    Button(action: share) {
                        Label("Share Notes", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("Share Private Notes")
                }

                // The episode note leads; timestamped notes follow in the query's timeline order.
                ForEach(notes.filter(\.isEpisodeWide) + notes.filter { !$0.isEpisodeWide }) { note in
                    card(for: note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .episodeNotesActions(actions)
        }
    }

    private func card(for note: EpisodeNoteRecord) -> some View {
        EpisodeNoteRowContent(note: note, onSeek: onSeek) {
            edit(note)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .compositingGroup()
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 12))
        .contextMenu {
            Button("Edit Note", systemImage: "square.and.pencil") { edit(note) }
                .accessibilityIdentifier("Edit Episode Note")
            Button("Delete Note", systemImage: "trash", role: .destructive) { delete(note) }
                .accessibilityIdentifier("Delete Episode Note")
        }
        .accessibilityAction(named: "Edit Note") { edit(note) }
        .accessibilityAction(named: "Delete Note") { delete(note) }
    }

    private func share() {
        actions.share(notes, episodeTitle: episodeTitle, showTitle: showTitle)
    }

    private func edit(_ note: EpisodeNoteRecord) {
        actions.edit(note, episodeTitle: episodeTitle)
    }

    private func delete(_ note: EpisodeNoteRecord) {
        actions.delete(note, in: modelContext)
    }
}
