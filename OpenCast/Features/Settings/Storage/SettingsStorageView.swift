import SwiftUI

struct SettingsStorageView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var isConfirmingClearCaches = false

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
                SettingsStorageDownloadsRow()
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

    private func confirmClearCaches() {
        isConfirmingClearCaches = true
    }

    private func clearCaches() {
        appModel.cacheController.clearCaches()
    }
}
