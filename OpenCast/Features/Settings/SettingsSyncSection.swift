import SwiftUI

struct SettingsSyncSection: View {
    let accountStatus: SyncAccountStatus
    let onRefresh: () -> Void

    var body: some View {
        Section {
            LabeledContent {
                Text(accountStatus.displayName)
            } label: {
                Label("Status", systemImage: "icloud")
            }
            if let detail = accountStatus.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            LabeledContent {
                Text("Syncs with iCloud")
            } label: {
                Label("Subscriptions", systemImage: "rectangle.stack.badge.play")
            }
            LabeledContent {
                Text("Syncs with iCloud")
            } label: {
                Label("Episode Progress", systemImage: "play.circle")
            }

            Button("Refresh Status", systemImage: "arrow.clockwise", action: onRefresh)
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Your podcast list and listening progress use private iCloud sync when available.")
        }
    }
}
