import SwiftUI

struct SettingsNotificationsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var notificationsEnabled = false

    var body: some View {
        let settings = appModel.notificationSettings
        Section("Notifications") {
            Toggle(
                "New Episode Notifications",
                isOn: $notificationsEnabled
            )
            .disabled(settings.isWorking)
            .onChange(of: notificationsEnabled) { _, isEnabled in
                guard isEnabled != settings.isEnabled else {
                    return
                }
                updateNotificationsEnabled(isEnabled)
            }

            LabeledContent("Status", value: settings.statusText)

            if settings.isPermissionDenied {
                Button(action: openSystemSettings) {
                    Label("Open Settings", systemImage: "gear")
                }
            }

            if let errorMessage = settings.lastErrorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await appModel.notificationSettings.refreshIfNeeded(
                activePodcastIDs: appModel.library.activePodcastIDs,
                modelContext: modelContext
            )
            notificationsEnabled = settings.isEnabled
        }
        .onChange(of: settings.isEnabled, initial: true) { _, isEnabled in
            notificationsEnabled = isEnabled
        }
    }

    private func updateNotificationsEnabled(_ isEnabled: Bool) {
        Task {
            await appModel.notificationSettings.setEnabled(
                isEnabled,
                activePodcastIDs: appModel.library.activePodcastIDs,
                modelContext: modelContext
            )
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        openURL(url)
    }
}
