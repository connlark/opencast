import SwiftUI

/// The model's proposals, one section each, between a line saying what part
/// of the show the model saw and the Apple Intelligence footer.
struct PlaylistOrganizerProposalsList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var drafts: [PlaylistProposalDraft]
    let scope: PlaylistOrganizerScope?
    let onAddEpisodes: (UUID) -> Void

    var body: some View {
        List {
            if let scope {
                Text(PlaylistOrganizerCopy.resultScope(scope))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("Playlist Organizer Result Scope")
            }

            ForEach(Array(drafts.enumerated()), id: \.element.id) { offset, draft in
                PlaylistProposalSection(
                    draft: binding(for: draft),
                    number: offset + 1,
                    onRemovePlaylist: { removeDraft(withID: draft.id) },
                    onAddEpisodes: { onAddEpisodes(draft.id) }
                )
            }

            Section {
            } footer: {
                Label(PlaylistOrganizerCopy.generatedFooter, systemImage: "apple.intelligence")
            }
        }
        .accessibilityIdentifier("Playlist Organizer Proposals")
    }

    /// Resolved by id rather than by index: a title field still committing
    /// while its proposal is removed must not write past the array's end.
    private func binding(for draft: PlaylistProposalDraft) -> Binding<PlaylistProposalDraft> {
        Binding {
            drafts.first { $0.id == draft.id } ?? draft
        } set: { updated in
            guard let index = drafts.firstIndex(where: { $0.id == updated.id }) else {
                return
            }
            drafts[index] = updated
        }
    }

    private func removeDraft(withID id: UUID) {
        withAnimation(reduceMotion ? nil : .default) {
            drafts.removeAll { $0.id == id }
        }
    }
}
