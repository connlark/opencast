import SwiftUI

struct SettingsDangerZoneSection: View {
    let onClearUnfollowedHistory: () -> Void
    let onNukeData: () -> Void

    @State private var isConfirmingClearUnfollowedHistory = false
    @State private var isConfirmingDataNuke = false

    var body: some View {
        Section {
            Button(
                "Clear History for Unfollowed Shows",
                systemImage: "clock.badge.xmark",
                role: .destructive,
                action: confirmClearUnfollowedHistory
            )
            .confirmationDialog(
                "Clear history for unfollowed shows?",
                isPresented: $isConfirmingClearUnfollowedHistory,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive, action: onClearUnfollowedHistory)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Played status and playback positions for every show you don't currently follow will be removed, and the change syncs to your other devices.")
            }

            Button(
                "Nuke opencast Data",
                systemImage: "trash",
                role: .destructive,
                action: confirmDataNuke
            )
            .confirmationDialog(
                "Nuke all opencast data?",
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
        }
    }

    private func confirmClearUnfollowedHistory() {
        isConfirmingClearUnfollowedHistory = true
    }

    private func confirmDataNuke() {
        isConfirmingDataNuke = true
    }
}
