import SwiftData
import SwiftUI

/// Downloads' Storage screen, pushed from the tab's toolbar: the bar by
/// show with its captions, then one legend row per segment.
struct DownloadsStorageView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var deleteErrorMessage: String?

    var body: some View {
        let library = appModel.library
        let model = DownloadsStorageGraphModel.make(
            breakdowns: DownloadsPodcastBreakdown.make(
                items: DownloadsListModel.make(records: appModel.downloads.records, library: library).downloaded,
                isSubscribed: { library.isActivelySubscribed(to: $0) }
            )
        )

        List {
            if model.totalEpisodeCount == 0 {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "internaldrive",
                    description: Text("Downloaded episodes and the space they use appear here.")
                )
            } else {
                Section {
                    DownloadsStorageSummaryView(model: model)
                }

                if !model.segments.isEmpty {
                    Section("Shows") {
                        ForEach(model.segments) { segment in
                            if segment.isOther {
                                DownloadsStorageOtherRow(segment: segment, onDelete: deleteDownloads)
                            } else if let breakdown = segment.members.first {
                                DownloadsStorageLegendRow(
                                    breakdown: breakdown,
                                    segment: segment,
                                    onDelete: { deleteDownloads(for: breakdown) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .settingsSubscreen(title: "Storage")
        .alert("Couldn’t Delete Downloads", item: $deleteErrorMessage) { _ in
        } message: { message in
            Text(message)
        }
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
