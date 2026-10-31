import SwiftUI

/// Presents the editor, the share sheet and the error alerts that an
/// `EpisodeNotesActions` asks for.
struct EpisodeNotesActionsPresenter: ViewModifier {
    @Bindable var actions: EpisodeNotesActions

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.editDraft) { draft in
                AddEpisodeNoteSheet(draft: draft)
            }
            .sheet(item: $actions.shareExport) { export in
                ActivityViewControllerSheet(
                    items: [EpisodeNotesActivityItem(export: export)],
                    onDismantle: export.removeFiles
                )
                .presentationDetents([.medium, .large])
            }
            .alert("Couldn’t Open Episode Note", item: $actions.openErrorMessage) { _ in
            } message: { message in
                Text(message)
            }
            .alert("Couldn’t Share Notes", item: $actions.shareErrorMessage) { _ in
            } message: { message in
                Text(message)
            }
            .alert("Couldn’t Delete Private Note", item: $actions.deleteErrorMessage) { _ in
            } message: { message in
                Text(message)
            }
    }
}

extension View {
    func episodeNotesActions(_ actions: EpisodeNotesActions) -> some View {
        modifier(EpisodeNotesActionsPresenter(actions: actions))
    }
}
