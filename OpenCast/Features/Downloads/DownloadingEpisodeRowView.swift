import SwiftData
import SwiftUI

struct DownloadingEpisodeRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let item: DownloadListItem

    private var isPaused: Bool {
        item.record.state == .paused
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkPlaceholder(
                title: item.episode.podcastTitle,
                imageURL: item.episode.artworkURL,
                size: 56,
                cacheKind: .episode,
                preview: item.episode.artworkPreview,
                onPreviewResolved: updateArtworkPreview
            )
            .overlay {
                DownloadArtworkProgressRing(
                    fractionCompleted: progressFraction,
                    isPaused: isPaused
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.episode.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.episode.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: togglePause) {
                Label(
                    isPaused ? "Resume Download" : "Pause Download",
                    systemImage: isPaused ? "play.fill" : "pause.fill"
                )
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityInputLabels(["Pause Download", "Resume Download"])
        }
        .padding(.vertical, 8)
        .swipeActions(edge: .trailing) {
            Button("Cancel", systemImage: "xmark", role: .destructive, action: cancelDownload)
        }
    }

    private var progressFraction: Double? {
        guard let bytesExpected = item.record.bytesExpected, bytesExpected > 0 else {
            return nil
        }

        return Double(max(item.record.bytesReceived, 0)) / Double(bytesExpected)
    }

    private var progressDescription: String {
        let received = max(item.record.bytesReceived, 0).formatted(.byteCount(style: .file))
        let byteDescription: String
        if let bytesExpected = item.record.bytesExpected, bytesExpected > 0 {
            byteDescription = "\(received) of \(bytesExpected.formatted(.byteCount(style: .file)))"
        } else if item.record.bytesReceived > 0 {
            byteDescription = "\(received) downloaded"
        } else {
            byteDescription = "Preparing download"
        }

        return isPaused ? "Paused, \(byteDescription)" : byteDescription
    }

    private func togglePause() {
        if isPaused {
            appModel.downloads.resumeDownload(
                episodeID: item.id,
                modelContext: modelContext
            )
        } else {
            appModel.downloads.pauseDownload(
                episodeID: item.id,
                modelContext: modelContext
            )
        }
    }

    private func cancelDownload() {
        appModel.downloads.cancelDownload(episodeID: item.id, modelContext: modelContext)
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        appModel.library.updateArtworkPreview(preview, for: item.episode)
    }
}
