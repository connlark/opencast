import SwiftData
import SwiftUI

/// One show's Download New Episodes and Keep Downloaded choices, pushed from
/// the Downloads screens and presented by `PodcastDownloadSettingsSheet`
/// from the show's actions menu. Unlike Skip Intro & Outro, whose free-text
/// fields validate into one synced write, these are discrete device-local
/// choices that apply on change, so turning a show on downloads at once.
struct PodcastDownloadSettingsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var isConfirmingDeleteDownloads = false

    let feedURL: String

    private var title: String {
        appModel.library.subscriptions.first { $0.feedURL == feedURL }?.title
            ?? appModel.library.podcastCache(for: feedURL)?.title
            ?? "Download Settings"
    }

    private var errorMessage: String? {
        appModel.downloadSettings.lastErrorMessage ?? appModel.downloads.lastErrorMessage
    }

    var body: some View {
        let completedRecords = appModel.downloads.records.filter {
            $0.podcastID == feedURL && $0.state == .completed
        }
        Form {
            Section {
                Toggle("Download New Episodes", isOn: autoDownloadBinding)
                    .accessibilityIdentifier("podcast-download-settings-auto-download-toggle")
            } footer: {
                Text(
                    appModel.downloadSettings.autoDownloadsRequireWiFi
                        ? "Downloads the newest episode now and each new episode when the show refreshes. Waits for Wi-Fi while Wi-Fi Only for Automatic Downloads is on."
                        : "Downloads the newest episode now and each new episode when the show refreshes. Uses any connection; turn on Wi-Fi Only in Download Settings to wait for Wi-Fi."
                )
            }

            Section {
                DownloadKeepLimitPicker(
                    selection: keepLimitBinding,
                    followedDefault: appModel.downloadSettings.defaultKeepLimit
                )
                .accessibilityIdentifier("podcast-download-settings-keep-limit-picker")

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(
                    "When this show has more downloads than its limit, the oldest downloads are removed. \(DownloadSettingsCopy.keptDownloadsSentence)"
                )
            }

            if !completedRecords.isEmpty {
                Section {
                    LabeledContent(
                        "Downloaded",
                        value: DownloadsStorageText.summary(
                            episodeCount: completedRecords.count,
                            byteCount: completedRecords.reduce(0) { $0 + max($1.bytesReceived, 0) }
                        )
                    )

                    Button(
                        "Delete This Show’s Downloads",
                        systemImage: "trash",
                        role: .destructive,
                        action: confirmDeleteDownloads
                    )
                    .confirmationDialog(
                        "Delete all downloads for this podcast?",
                        isPresented: $isConfirmingDeleteDownloads,
                        titleVisibility: .visible
                    ) {
                        Button("Delete All Downloads", role: .destructive, action: deleteDownloads)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Downloaded audio for this podcast will be removed from this device.")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var autoDownloadBinding: Binding<Bool> {
        Binding {
            appModel.downloadSettings.autoDownloadsNewEpisodes(forPodcastID: feedURL)
        } set: { isEnabled in
            appModel.setAutoDownloadsNewEpisodes(isEnabled, forPodcastID: feedURL, modelContext: modelContext)
        }
    }

    private var keepLimitBinding: Binding<DownloadKeepLimit?> {
        Binding {
            appModel.downloadSettings.keepLimitOverride(forPodcastID: feedURL)
        } set: { keepLimit in
            appModel.setKeepLimitOverride(keepLimit, forPodcastID: feedURL, modelContext: modelContext)
        }
    }

    private func confirmDeleteDownloads() {
        isConfirmingDeleteDownloads = true
    }

    private func deleteDownloads() {
        appModel.deleteDownloads(forPodcastID: feedURL, modelContext: modelContext)
    }
}
