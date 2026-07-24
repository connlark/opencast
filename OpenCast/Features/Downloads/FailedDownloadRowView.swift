import SwiftData
import SwiftUI

struct FailedDownloadRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let item: DownloadListItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkPlaceholder(
                title: item.episode.podcastTitle,
                imageURL: item.episode.artworkURL,
                size: 56,
                cacheKind: .episode,
                preview: appModel.library.artworkPreview(for: item.episode),
                onPreviewResolved: updateArtworkPreview
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.episode.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.episode.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: retryDownload) {
                Label("Retry Download", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: deleteDownload)
        }
        .swipeActions(edge: .leading) {
            Button("Retry", systemImage: "arrow.clockwise", action: retryDownload)
                .tint(.blue)
        }
    }

    private var errorMessage: String {
        item.record.errorMessage ?? "The download could not be completed."
    }

    private func retryDownload() {
        appModel.downloads.retryDownload(item.record, modelContext: modelContext)
    }

    private func deleteDownload() {
        appModel.deleteDownload(item.record, modelContext: modelContext)
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        appModel.library.updateArtworkPreview(preview, for: item.episode)
    }
}
