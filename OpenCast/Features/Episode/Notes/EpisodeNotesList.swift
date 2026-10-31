import SwiftData
import SwiftUI

/// The Now Playing notes sheet: the episode note (or a row to add one), then
/// the timestamped notes, with swipe actions to edit and delete.
struct EpisodeNotesList: View {
    @Environment(\.modelContext) private var modelContext
    @State private var actions = EpisodeNotesActions()
    @Query private var notes: [EpisodeNoteRecord]
    let episodeID: String
    let episodeTitle: String
    let showTitle: String
    let onSeek: (TimeInterval) -> Void

    init(episodeID: String, episodeTitle: String, showTitle: String, onSeek: @escaping (TimeInterval) -> Void) {
        _notes = Query(EpisodeNoteStore.notes(for: episodeID))
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.showTitle = showTitle
        self.onSeek = onSeek
    }

    var body: some View {
        let episodeNotes = notes.filter(\.isEpisodeWide)
        let timestampedNotes = notes.filter { !$0.isEpisodeWide }
        List {
            Section {
                if episodeNotes.isEmpty {
                    Button("Add Episode Note", systemImage: "square.and.pencil", action: addEpisodeNote)
                        .accessibilityIdentifier("Add Whole Episode Note")
                } else {
                    ForEach(episodeNotes, content: row)
                }
            }

            if notes.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "note.text",
                    description: Text("Add a note from Now Playing, or an episode note from the episode's actions menu.")
                )
                .listRowBackground(Color.clear)
            } else if !timestampedNotes.isEmpty {
                Section {
                    ForEach(timestampedNotes, content: row)
                }
            }
        }
        .toolbar {
            if !notes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share Notes", systemImage: "square.and.arrow.up", action: share)
                        .accessibilityIdentifier("Share Private Notes")
                }
            }
        }
        .episodeNotesActions(actions)
    }

    private func row(for note: EpisodeNoteRecord) -> some View {
        EpisodeNoteRowContent(note: note, onSeek: onSeek) {
            edit(note)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(note) }
        }
        .swipeActions(edge: .leading) {
            Button("Edit", systemImage: "square.and.pencil") { edit(note) }
                .tint(.accentColor)
        }
        .contextMenu {
            Button("Edit Note", systemImage: "square.and.pencil") { edit(note) }
                .accessibilityIdentifier("Edit Episode Note")
            Button("Delete Note", systemImage: "trash", role: .destructive) { delete(note) }
                .accessibilityIdentifier("Delete Episode Note")
        }
    }

    private func addEpisodeNote() {
        actions.addEpisodeNote(episodeID: episodeID, episodeTitle: episodeTitle, in: modelContext)
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
