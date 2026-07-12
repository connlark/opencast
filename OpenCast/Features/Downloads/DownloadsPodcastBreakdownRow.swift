import SwiftUI

struct DownloadsPodcastBreakdownRow: View {
    let breakdown: DownloadsPodcastBreakdown
    let onDelete: () -> Void

    var body: some View {
        LabeledContent {
            Text(storageDescription)
                .foregroundStyle(.secondary)
        } label: {
            Text(breakdown.title)
        }
        .accessibilityIdentifier("download-podcast-\(breakdown.podcastID)")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var storageDescription: String {
        let episodeLabel = breakdown.episodeCount == 1 ? "episode" : "episodes"
        return "\(breakdown.episodeCount) \(episodeLabel), \(breakdown.byteCount.formatted(.byteCount(style: .file)))"
    }
}
