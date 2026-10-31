import SwiftData
import SwiftUI

struct EpisodeNotesSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var editDraft: EpisodeNoteDraft?
    @State private var shareExport: EpisodeNotesShare?
    @State private var shareError: String?
    @State private var deletionError: String?
    @Query private var notes: [EpisodeNoteRecord]
    let episodeTitle: String
    let showTitle: String
    let showsHeading: Bool
    let onSeek: (TimeInterval) -> Void

    init(episodeID: String, episodeTitle: String, showTitle: String, showsHeading: Bool = true, onSeek: @escaping (TimeInterval) -> Void) {
        let id = episodeID
        _notes = Query(
            filter: #Predicate<EpisodeNoteRecord> { $0.episodeID == id },
            sort: [SortDescriptor(\EpisodeNoteRecord.timestamp), SortDescriptor(\EpisodeNoteRecord.createdAt)]
        )
        self.episodeTitle = episodeTitle
        self.showTitle = showTitle
        self.showsHeading = showsHeading
        self.onSeek = onSeek
    }

    var body: some View {
        if !notes.isEmpty || !showsHeading {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeading {
                Label("Private Notes", systemImage: "note.text")
                    .font(.headline)
            }
            if showsHeading && !notes.isEmpty {
                shareButton
            }
            if notes.isEmpty {
                ContentUnavailableView("No Notes Yet", systemImage: "note.text", description: Text("Add a timestamped note from Now Playing, or a note for the whole episode from its Episode Actions menu."))
            } else {
                // Stable sorting lifts the episode note without changing the query's timestamp order.
                ForEach(notes.sorted { $0.isEpisodeWide && !$1.isEpisodeWide }) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        if note.isEpisodeWide {
                            Button("Episode Note", systemImage: "square.and.pencil") {
                                edit(note)
                            }
                            .accessibilityLabel("Edit Episode Note")
                            .accessibilityIdentifier("Edit Whole Episode Note")
                        } else {
                            HStack {
                                Button {
                                    onSeek(note.timestamp)
                                } label: {
                                    Label(note.timestamp.formattedPlaybackDuration, systemImage: "play.circle")
                                        .font(.subheadline.monospacedDigit())
                                }
                                .accessibilityLabel("Play from \(note.timestamp.formattedPlaybackDuration)")
                            }
                        }
                        Text(note.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .compositingGroup()
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
                    .contextMenu {
                        Button("Edit Note", systemImage: "square.and.pencil") { edit(note) }
                            .accessibilityIdentifier("Edit Episode Note")
                        Button("Delete Note", systemImage: "trash", role: .destructive) {
                            delete(note)
                        }
                        .accessibilityIdentifier("Delete Episode Note")
                    }
                    .accessibilityAction(named: "Edit Note") { edit(note) }
                    .accessibilityAction(named: "Delete Note") {
                        delete(note)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar {
            if !showsHeading && !notes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    shareButton.labelStyle(.iconOnly)
                }
            }
        }
        .sheet(item: $editDraft) { draft in
            AddEpisodeNoteSheet(draft: draft)
        }
        .sheet(item: $shareExport) { export in
            EpisodeNotesActivitySheet(export: export)
        }
        .alert("Couldn’t Share Notes", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .alert("Couldn’t Delete Private Note", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    private var shareButton: some View {
        Button("Share Notes", systemImage: "square.and.arrow.up") {
            do {
                shareExport = try EpisodeNotesShare(episodeTitle: episodeTitle, showTitle: showTitle, notes: notes)
            } catch { shareError = error.localizedDescription }
        }
        .accessibilityIdentifier("Share Private Notes")
    }

    private func edit(_ note: EpisodeNoteRecord) {
        editDraft = EpisodeNoteDraft(episodeID: note.episodeID, episodeTitle: episodeTitle, timestamp: note.timestamp, noteID: note.noteID, initialText: note.text, isEpisodeWide: note.isEpisodeWide)
    }

    private func delete(_ note: EpisodeNoteRecord) {
        do {
            try EpisodeNoteStore.delete(note, in: modelContext)
        } catch {
            deletionError = error.localizedDescription
        }
    }
}
