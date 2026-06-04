import SwiftUI

struct SettingsDangerZoneSection: View {
    let onNukeData: () -> Void

    @State private var isConfirmingDataNuke = false

    var body: some View {
        Section {
            Button(
                "Nuke OpenCast Data",
                systemImage: "trash",
                role: .destructive,
                action: confirmDataNuke
            )
            .confirmationDialog(
                "Nuke all OpenCast data?",
                isPresented: $isConfirmingDataNuke,
                titleVisibility: .visible
            ) {
                Button("Continue", role: .destructive, action: onNukeData)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This starts a final confirmation step before deleting synced subscriptions, synced listening progress, local downloads, caches, and settings.")
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("The final delete checks iCloud account status again. If OpenCast cannot confirm that iCloud is available, no data is deleted.")
        }
    }

    private func confirmDataNuke() {
        isConfirmingDataNuke = true
    }
}
