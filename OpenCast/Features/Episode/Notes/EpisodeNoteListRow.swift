import SwiftUI

struct EpisodeNoteListRow: View {
    let note: EpisodeNoteRecord
    let onSeek: (TimeInterval) -> Void
    let onEdit: (EpisodeNoteRecord) -> Void
    let onDelete: (EpisodeNoteRecord) -> Void

    var body: some View {
        EpisodeNoteRowContent(note: note, onSeek: onSeek, onEdit: edit)
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .swipeActions(edge: .leading) {
                Button("Edit", systemImage: "square.and.pencil", action: edit)
                    .tint(.accentColor)
            }
            .contextMenu {
                Button("Edit Note", systemImage: "square.and.pencil", action: edit)
                    .accessibilityIdentifier("Edit Episode Note")
                Button("Delete Note", systemImage: "trash", role: .destructive, action: delete)
                    .accessibilityIdentifier("Delete Episode Note")
            }
    }

    private func edit() {
        onEdit(note)
    }

    private func delete() {
        onDelete(note)
    }
}
