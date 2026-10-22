import SwiftData
import SwiftUI

/// The Downloads tab's Storage section rows: the bar with its captions,
/// then one legend row per segment.
struct DownloadsStorageHeaderView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var availableByteCount: Int64?
    @State private var deleteErrorMessage: String?

    let model: DownloadsStorageGraphModel
    let onOpenShowSettings: (String) -> Void

    var body: some View {
        // Modifiers on this Group's rows would apply to every row, so the
        // capacity read and the error alert live on the summary row alone.
        Group {
            summary
                .task(id: model.totalByteCount) {
                    availableByteCount = await DownloadsDeviceCapacity.availableForImportantUsage()
                }
                .alert("Couldn’t Delete Downloads", item: $deleteErrorMessage) { _ in
                } message: { message in
                    Text(message)
                }

            ForEach(model.segments) { segment in
                if segment.isOther {
                    DownloadsStorageOtherRow(
                        segment: segment,
                        onOpenSettings: openSettings,
                        onDelete: deleteDownloads
                    )
                } else if let breakdown = segment.members.first {
                    DownloadsStorageLegendRow(
                        breakdown: breakdown,
                        segment: segment,
                        onOpenSettings: { openSettings(for: breakdown) },
                        onDelete: { deleteDownloads(for: breakdown) }
                    )
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.segments.isEmpty {
                DownloadsStorageBarView(model: model)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    DownloadsStorageText.summary(
                        episodeCount: model.totalEpisodeCount,
                        byteCount: model.totalByteCount
                    )
                )
                if let availableByteCount {
                    Text("\(DownloadsStorageText.size(availableByteCount)) available on this device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func openSettings(for breakdown: DownloadsPodcastBreakdown) {
        onOpenShowSettings(breakdown.podcastID)
    }

    private func deleteDownloads(for breakdown: DownloadsPodcastBreakdown) {
        do {
            try appModel.deleteCompletedDownloads(
                forPodcastID: breakdown.podcastID,
                modelContext: modelContext
            )
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }
}
