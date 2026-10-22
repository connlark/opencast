import SwiftUI

/// Settings › Storage's route to Download Settings, which lives in the
/// Downloads tab. It is a button rather than a link because it changes tabs.
struct SettingsStorageDownloadsRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.openDownloadSettings) private var openDownloadSettings

    private var summary: String {
        let count = appModel.downloads.completedDownloadCount
        guard count > 0 else {
            return "None"
        }
        return DownloadsStorageText.summary(
            episodeCount: count,
            byteCount: appModel.downloads.completedDownloadByteCount
        )
    }

    var body: some View {
        Button(action: open) {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(summary)
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
            // A button tints its label; the concrete primary keeps the row
            // reading like the navigation rows beside it, value and all.
            .foregroundStyle(Color.primary)
        }
        .disabled(openDownloadSettings == nil)
        .accessibilityIdentifier("Settings Row Downloads")
    }

    private func open() {
        openDownloadSettings?()
    }
}
