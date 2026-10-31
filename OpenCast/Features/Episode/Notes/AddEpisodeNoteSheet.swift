import SwiftData
import SwiftUI

struct AddEpisodeNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text: String
    @State private var errorMessage: String?
    @FocusState private var isEditing: Bool

    /// Callers resolve an existing note into the draft before presenting, so
    /// the editor opens with its text and never fetches.
    let draft: EpisodeNoteDraft

    init(draft: EpisodeNoteDraft) {
        self.draft = draft
        _text = State(initialValue: draft.initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.episodeTitle)
                    .font(.headline)
                    .lineLimit(3)
                if !draft.isEpisodeWide {
                    Label(draft.timestamp.formattedPlaybackDuration, systemImage: "clock")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $text)
                    .focused($isEditing)
                    .accessibilityLabel("Private Note")
                    .accessibilityIdentifier("Episode Note Text")
                    .padding(8)
                    .background(.quaternary, in: .rect(cornerRadius: 12))
            }
            .padding()
            .navigationTitle(draft.noteID != nil ? "Edit Private Note" : "Add Private Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!hasText)
                        .accessibilityIdentifier("Save Episode Note")
                }
            }
            .alert("Couldn’t Save Private Note", item: $errorMessage) { _ in
            } message: { message in
                Text(message)
            }
            .task {
                isEditing = true
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasText)
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        do {
            try EpisodeNoteStore.save(text, for: draft, in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
