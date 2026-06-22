import SwiftData
import SwiftUI

struct NotificationOptInView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        let settings = appModel.notificationSettings

        VStack(alignment: .leading, spacing: 18) {
            Label(statusTitle, systemImage: statusSystemImage)
                .font(.headline)
                .foregroundStyle(statusColor)

            Text(statusMessage)
                .font(.body)
                .foregroundStyle(.secondary)

            Button(action: enableNotifications) {
                HStack(spacing: 10) {
                    if settings.isWorking {
                        ProgressView()
                    } else {
                        Image(systemName: primaryActionSystemImage)
                    }

                    Text(primaryActionTitle)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glassProminent)
            .disabled(settings.isWorking || settings.isEnabled)
            .accessibilityIdentifier("Enable Notifications")

            if settings.isPermissionDenied {
                Button("Open Settings", systemImage: "gear", action: openSystemSettings)
                    .buttonStyle(.glass)
            }

            if let errorMessage = settings.lastErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {

                Text("opencast only sends notifications when a new episode is available from a podcast you follow. Never any marketing, promotions, or recommendations.")
                    .font(.subheadline)
                    //.italic()
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy")
                    .font(.headline)

                Text("Notifications work without an account.")

                Text("When enabled, opencast sends a random install ID and App Attest proof, your APNs token and environment, app version and build, and your enabled RSS feed URL list.")

                Text("The server does *not* store an account, email, Apple ID, raw IP address, listening history, raw feed XML, show notes, or audio URLs.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .task {
            await appModel.notificationSettings.refreshIfNeeded(
                activePodcastIDs: appModel.library.activePodcastIDs,
                modelContext: modelContext
            )
        }
    }

    private var statusTitle: String {
        let settings = appModel.notificationSettings
        if settings.isPermissionDenied {
            return "Notifications are blocked"
        }
        if settings.isEnabled {
            return "Notifications are on"
        }
        return "Notifications are off"
    }

    private var statusMessage: String {
        let settings = appModel.notificationSettings
        if settings.isWorking {
            return "Setting up notification registration and syncing your current subscriptions."
        }
        if settings.isEnabled {
            return settings.statusText
        }
        if settings.isPermissionDenied {
            return "Allow notifications in Settings to receive new episode alerts."
        }
        return "Enable alerts now, or skip this and turn them on later in Settings."
    }

    private var statusSystemImage: String {
        let settings = appModel.notificationSettings
        if settings.isPermissionDenied {
            return "bell.slash"
        }
        if settings.isEnabled {
            return "bell.badge.fill"
        }
        return "bell"
    }

    private var statusColor: Color {
        appModel.notificationSettings.isPermissionDenied ? .orange : .primary
    }

    private var primaryActionTitle: String {
        let settings = appModel.notificationSettings
        if settings.isEnabled {
            return "Notifications Enabled"
        }
        if settings.isWorking {
            return "Setting Up"
        }
        return "Enable Notifications"
    }

    private var primaryActionSystemImage: String {
        appModel.notificationSettings.isEnabled ? "checkmark" : "bell.badge"
    }

    private func enableNotifications() {
        Task {
            await appModel.notificationSettings.setEnabled(
                true,
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
