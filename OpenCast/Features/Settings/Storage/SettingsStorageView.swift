import SwiftData
import SwiftUI

struct SettingsStorageView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var isConfirmingClearCaches = false
    @State private var isConfirmingDeleteAllDownloads = false

    var body: some View {
        Form {
            Section("Caches") {
                LabeledContent {
                    Text(appModel.cacheController.feedCacheSummary.storageDescription)
                } label: {
                    Label("Feed Cache", systemImage: "internaldrive")
                }

                LabeledContent {
                    Text(appModel.cacheController.artworkCacheSummary.storageDescription)
                } label: {
                    Label("Artwork Cache", systemImage: "photo")
                }

                Button("Clear Automatic Caches", systemImage: "trash", role: .destructive, action: confirmClearCaches)
                    .confirmationDialog(
                        "Clear automatic caches?",
                        isPresented: $isConfirmingClearCaches,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Automatic Caches", role: .destructive, action: clearCaches)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Feed and artwork cache files will be removed from this device. Downloaded episodes are unchanged.")
                    }

                if let cacheErrorMessage = appModel.cacheController.lastErrorMessage {
                    Label(cacheErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent {
                    Text(downloadStorageSummary)
                } label: {
                    Label("Downloaded Episodes", systemImage: "arrow.down.circle")
                }

                Toggle("Delete Downloads After Played", isOn: autoDeletePlayedDownloadsBinding)

                if appModel.downloads.completedDownloadCount > 0 {
                    Button(
                        "Delete All Downloads",
                        systemImage: "trash",
                        role: .destructive,
                        action: confirmDeleteAllDownloads
                    )
                    .confirmationDialog(
                        "Delete all downloaded episodes?",
                        isPresented: $isConfirmingDeleteAllDownloads,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Downloads", role: .destructive, action: deleteAllDownloads)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Downloaded files will be removed from this device. Subscriptions and listening progress are unchanged.")
                    }
                }

                if let downloadErrorMessage = appModel.downloads.lastErrorMessage {
                    Label(downloadErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Downloads")
            } footer: {
                HelpFooterLink(title: "How storage works", topicID: HelpTopicID.storage)
            }
        }
        .settingsSubscreen(title: "Storage")
        .task {
            appModel.cacheController.refreshSummaries()
        }
    }

    private var downloadStorageSummary: String {
        let count = appModel.downloads.completedDownloadCount
        guard count > 0 else {
            return "None"
        }

        let episodeLabel = count == 1 ? "episode" : "episodes"
        return "\(count) \(episodeLabel), \(appModel.downloads.completedDownloadByteCount.formatted(.byteCount(style: .file)))"
    }

    private var autoDeletePlayedDownloadsBinding: Binding<Bool> {
        Binding {
            appModel.downloads.autoDeletesPlayedDownloads
        } set: { isEnabled in
            appModel.downloads.setAutoDeletesPlayedDownloads(isEnabled, modelContext: modelContext)
        }
    }

    private func confirmClearCaches() {
        isConfirmingClearCaches = true
    }

    private func clearCaches() {
        appModel.cacheController.clearCaches()
    }

    private func confirmDeleteAllDownloads() {
        isConfirmingDeleteAllDownloads = true
    }

    private func deleteAllDownloads() {
        appModel.deleteAllDownloads(modelContext: modelContext)
    }
}
