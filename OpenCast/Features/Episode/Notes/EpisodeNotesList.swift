import SwiftData
import SwiftUI

/// The Now Playing notes sheet: the episode note (or a row to add one), then
/// the timestamped notes, with swipe actions to edit and delete.
struct EpisodeNotesList: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var actions = EpisodeNotesActions()
    @State private var notes: [EpisodeNoteRecord] = []
    let episode: EpisodeListItemSnapshot
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
        .task(id: EpisodeNotesFetchKey(episodeID: episode.episodeID, revision: appModel.episodeNotes.revision(for: episode.episodeID))) {
            notes = (try? modelContext.fetch(EpisodeNoteStore.notes(for: episode.episodeID))) ?? []
        }
    }

    private func row(for note: EpisodeNoteRecord) -> some View {
        EpisodeNoteListRow(note: note, onSeek: onSeek, onEdit: edit, onDelete: delete)
    }

    private func addEpisodeNote() {
        actions.addEpisodeNote(episode: episode, in: modelContext)
    }

    private func share() {
        actions.share(notes, episodeTitle: episode.title, showTitle: episode.podcastTitle)
    }

    private func edit(_ note: EpisodeNoteRecord) {
        actions.edit(note, episode: episode)
    }

    private func delete(_ note: EpisodeNoteRecord) {
        if actions.delete(note, in: modelContext) {
            appModel.episodeNotes.notesDidChange(episodeID: episode.episodeID)
        }
    }
}
