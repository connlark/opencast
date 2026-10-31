import SwiftData
import SwiftUI

/// The Now Playing notes sheet: the episode note (or a row to add one), then
/// the timestamped notes, with swipe actions to edit and delete.
struct EpisodeNotesList: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var actions = EpisodeNotesActions()
    @State private var notes: [EpisodeNoteRecord] = []
    let episodeID: String
    let episodeTitle: String
    let showTitle: String
    let onSeek: (TimeInterval) -> Void

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
        .task(id: EpisodeNotesFetchKey(episodeID: episodeID, revision: appModel.episodeNotes.revision(for: episodeID))) {
            notes = (try? modelContext.fetch(EpisodeNoteStore.notes(for: episodeID))) ?? []
        }
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
        if actions.delete(note, in: modelContext) {
            appModel.episodeNotes.notesDidChange(episodeID: episodeID)
        }
    }
}
