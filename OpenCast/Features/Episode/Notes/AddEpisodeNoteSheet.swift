import SwiftData
import SwiftUI

struct AddEpisodeNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @State private var editingNoteID: String?
    @State private var errorMessage: String?
    @FocusState private var isEditing: Bool

    let draft: EpisodeNoteDraft

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
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .navigationTitle(editingNoteID != nil ? "Edit Private Note" : "Add Private Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var savedDraft = draft
                            savedDraft.noteID = editingNoteID
                            try EpisodeNoteStore.save(text, for: savedDraft, in: modelContext)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Save Episode Note")
                }
            }
            .alert("Couldn’t Save Private Note", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                editingNoteID = draft.noteID
                text = draft.initialText
                if draft.isEpisodeWide && draft.noteID == nil {
                    let episodeID = draft.episodeID
                    do {
                        if let existing = try modelContext.fetch(FetchDescriptor<EpisodeNoteRecord>(
                            predicate: #Predicate { $0.episodeID == episodeID && $0.isEpisodeWide }
                        )).first {
                            editingNoteID = existing.noteID
                            text = existing.text
                        }
                    } catch { errorMessage = error.localizedDescription }
                }
                isEditing = true
            }

        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
