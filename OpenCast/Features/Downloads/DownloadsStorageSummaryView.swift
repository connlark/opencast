import SwiftData
import SwiftUI

struct DownloadsStorageSummaryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingDeleteAll = false
    @State private var isShowingDeleteError = false
    @State private var deleteErrorMessage = ""

    let breakdowns: [DownloadsPodcastBreakdown]

    var body: some View {
        Group {
            LabeledContent {
                Text(storageDescription)
            } label: {
                Label("Downloaded Episodes", systemImage: "arrow.down.circle")
            }

            if !breakdowns.isEmpty {
                DisclosureGroup("By Podcast") {
                    ForEach(breakdowns) { breakdown in
                        DownloadsPodcastBreakdownRow(
                            breakdown: breakdown,
                            onDelete: { deleteDownloads(for: breakdown) }
                        )
                    }
                }
            }

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
        }
        .alert("Couldn’t Delete Downloads", isPresented: $isShowingDeleteError) {
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private var storageDescription: String {
        let count = appModel.downloads.completedDownloadCount
        let episodeLabel = count == 1 ? "episode" : "episodes"
        return "\(count) \(episodeLabel), \(appModel.downloads.completedDownloadByteCount.formatted(.byteCount(style: .file)))"
    }

    private func confirmDeleteAll() {
        isConfirmingDeleteAll = true
    }

    private func deleteAllDownloads() {
        appModel.deleteAllDownloads(modelContext: modelContext)
    }

    private func deleteDownloads(for breakdown: DownloadsPodcastBreakdown) {
        do {
            try appModel.deleteCompletedDownloads(
                forPodcastID: breakdown.podcastID,
                modelContext: modelContext
            )
        } catch {
            deleteErrorMessage = error.localizedDescription
            isShowingDeleteError = true
        }
    }
}
