import SwiftUI

/// Edit mode's actions under the list. They confirm with alerts: from
/// this bar a confirmation dialog's popover sits beside its button and
/// zooms in from the wrong point.
struct DownloadsEditActionsView: View {
    let selectedCount: Int
    let playedDownloadCount: Int
    @Binding var isConfirmingDeleteSelected: Bool
    @Binding var isConfirmingRemovePlayed: Bool
    let onDeleteSelected: () -> Void
    let onRemovePlayed: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button(
                    deleteTitle,
                    systemImage: "trash",
                    role: .destructive,
                    action: confirmDeleteSelected
                )
                .lineLimit(1)
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(selectedCount == 0)
                .accessibilityInputLabels(["Delete", "Delete Selected"])
                .accessibilityIdentifier("downloads-delete-selected")
                .alert(
                    "Delete selected downloads?",
                    isPresented: $isConfirmingDeleteSelected
                ) {
                    Button("Delete Selected", role: .destructive, action: onDeleteSelected)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The selected downloaded files will be removed from this device.")
                }

                Spacer(minLength: 0)

                Button(
                    "Remove Played",
                    systemImage: "checkmark.circle",
                    role: .destructive,
                    action: confirmRemovePlayed
                )
                .lineLimit(1)
                .buttonStyle(.glass)
                .tint(.red)
                .disabled(playedDownloadCount == 0)
                .alert(
                    "Remove played downloads?",
                    isPresented: $isConfirmingRemovePlayed
                ) {
                    Button("Remove Played", role: .destructive, action: onRemovePlayed)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Played downloads that aren’t currently in use will be removed from this device.")
                }
            }
        }
    }

    /// Short enough to stay on one line beside Remove Played; the count
    /// appears once something is selected.
    private var deleteTitle: String {
        selectedCount == 0 ? "Delete" : "Delete (\(selectedCount))"
    }

    private func confirmDeleteSelected() {
        isConfirmingDeleteSelected = true
    }

    private func confirmRemovePlayed() {
        isConfirmingRemovePlayed = true
    }
}
