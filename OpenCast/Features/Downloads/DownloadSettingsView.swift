import SwiftData
import SwiftUI

/// The one home for download settings, pushed from the Downloads tab and
/// reached from Settings › Storage. Every control applies on change.
struct DownloadSettingsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var isConfirmingDeleteAll = false

    private var errorMessage: String? {
        appModel.downloadSettings.lastErrorMessage ?? appModel.downloads.lastErrorMessage
    }

    var body: some View {
        Form {
            Section {
                Toggle("Wi-Fi Only for Automatic Downloads", isOn: requiresWiFiBinding)
                    .accessibilityIdentifier("download-settings-wifi-only-toggle")
            } footer: {
                Text("Shows set to download new episodes wait for Wi-Fi. Downloads you start yourself use any connection.")
            }

            Section {
                DownloadKeepLimitPicker(selection: defaultKeepLimitBinding)
                    .accessibilityIdentifier("download-settings-keep-limit-picker")

                Toggle("Delete Downloads After Played", isOn: autoDeletesPlayedDownloadsBinding)
                    .accessibilityIdentifier("download-settings-auto-delete-toggle")

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(
                    "Keep Downloaded applies to every show without its own limit. When a show has more downloads than its limit, the oldest downloads are removed. \(DownloadSettingsCopy.keptDownloadsSentence)"
                )
            }

            Section("Shows") {
                if appModel.library.subscriptions.isEmpty {
                    Text("Subscribe to a show to set its download options.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.library.subscriptions) { subscription in
                        NavigationLink(value: AppRoute.podcastDownloadSettings(feedURL: subscription.feedURL)) {
                            DownloadSettingsShowRow(subscription: subscription)
                        }
                        .accessibilityIdentifier("download-settings-show-\(subscription.feedURL)")
                    }
                }
            }

            Section {
                if appModel.downloads.completedDownloadCount > 0 {
                    Button(
                        "Delete All Downloads",
                        systemImage: "trash",
                        role: .destructive,
                        action: confirmDeleteAll
                    )
                    .confirmationDialog(
                        "Delete all downloaded episodes?",
                        isPresented: $isConfirmingDeleteAll,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Downloads", role: .destructive, action: deleteAllDownloads)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Downloaded files will be removed from this device. Subscriptions and listening progress are unchanged.")
                    }
                }
            } footer: {
                HelpFooterLink(title: "How downloads and storage work", topicID: HelpTopicID.storage)
            }
        }
        .settingsSubscreen(title: "Download Settings")
    }

    private var requiresWiFiBinding: Binding<Bool> {
        Binding {
            appModel.downloadSettings.autoDownloadsRequireWiFi
        } set: { requiresWiFi in
            appModel.setAutoDownloadsRequireWiFi(requiresWiFi, modelContext: modelContext)
        }
    }

    /// The default always has a value; the picker's nil tag belongs to a
    /// show's Default row, which this picker leaves out.
    private var defaultKeepLimitBinding: Binding<DownloadKeepLimit?> {
        Binding {
            appModel.downloadSettings.defaultKeepLimit
        } set: { keepLimit in
            guard let keepLimit else {
                return
            }
            appModel.setDefaultKeepLimit(keepLimit, modelContext: modelContext)
        }
    }

    private var autoDeletesPlayedDownloadsBinding: Binding<Bool> {
        Binding {
            appModel.downloads.autoDeletesPlayedDownloads
        } set: { isEnabled in
            appModel.downloads.setAutoDeletesPlayedDownloads(isEnabled, modelContext: modelContext)
        }
    }

    private func confirmDeleteAll() {
        isConfirmingDeleteAll = true
    }

    private func deleteAllDownloads() {
        appModel.deleteAllDownloads(modelContext: modelContext)
    }
}
