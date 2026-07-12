import SwiftUI

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
                    "Delete Selected (\(selectedCount))",
                    systemImage: "trash",
                    role: .destructive,
                    action: confirmDeleteSelected
                )
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(selectedCount == 0)
                .confirmationDialog(
                    "Delete selected downloads?",
                    isPresented: $isConfirmingDeleteSelected,
                    titleVisibility: .visible
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
                .buttonStyle(.glass)
                .tint(.red)
                .disabled(playedDownloadCount == 0)
                .confirmationDialog(
                    "Remove played downloads?",
                    isPresented: $isConfirmingRemovePlayed,
                    titleVisibility: .visible
                ) {
                    Button("Remove Played", role: .destructive, action: onRemovePlayed)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Played downloads that aren’t currently in use will be removed from this device.")
                }
            }
        }
    }

    private func confirmDeleteSelected() {
        isConfirmingDeleteSelected = true
    }

    private func confirmRemovePlayed() {
        isConfirmingRemovePlayed = true
    }
}
