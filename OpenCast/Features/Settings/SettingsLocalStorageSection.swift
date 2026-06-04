import SwiftUI

struct SettingsLocalStorageSection: View {
    let feedCacheSummary: String
    let artworkCacheSummary: String
    let cacheErrorMessage: String?
    let downloadStorageSummary: String
    let completedDownloadCount: Int
    let downloadErrorMessage: String?
    let onClearCaches: () -> Void
    let onDeleteAllDownloads: () -> Void

    var body: some View {
        Section {
            LabeledContent {
                Text(feedCacheSummary)
            } label: {
                Label("Feed Cache", systemImage: "internaldrive")
            }
            LabeledContent {
                Text(artworkCacheSummary)
            } label: {
                Label("Artwork Cache", systemImage: "photo")
            }
            LabeledContent {
                Text("On this device")
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            LabeledContent {
                Text(downloadStorageSummary)
            } label: {
                Label("Downloaded Episodes", systemImage: "arrow.down.circle")
            }

            Button("Clear Automatic Caches", systemImage: "trash", role: .destructive, action: onClearCaches)

            if completedDownloadCount > 0 {
                Button(
                    "Delete All Downloads",
                    systemImage: "trash",
                    role: .destructive,
                    action: onDeleteAllDownloads
                )
            }

            if let cacheErrorMessage {
                Label(cacheErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let downloadErrorMessage {
                Label(downloadErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Local Storage")
        }
    }
}
