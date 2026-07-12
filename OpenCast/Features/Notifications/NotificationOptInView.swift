import SwiftData
import SwiftUI

struct NotificationOptInView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        let settings = appModel.notificationSettings

        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)

                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                SymbolBadgeView(
                    systemImage: statusSystemImage,
                    color: settings.isPermissionDenied ? .orange : .red,
                    isShowingProgress: settings.isWorking,
                    fillOpacity: settings.isPermissionDenied ? 0.18 : 0.14
                )
            }
            .accessibilityElement(children: .combine)

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
            .controlSize(.large)
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
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
            return "Alerts are active for your followed podcasts."
        }
        if settings.isPermissionDenied {
            return "Allow notifications in Settings to receive new episode alerts."
        }
        return "Turn on alerts now, or skip and enable them later from Settings."
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
