import SwiftUI

struct AdDetectionQueueRowView: View {
    let row: AdDetectionQueuePresentation.Row

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkPlaceholder(
                title: row.episodeTitle,
                imageURL: row.artworkURL,
                size: 44,
                cacheKind: .episode
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(row.episodeTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(row.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusIcon
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.2), value: row.status)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ad-detection-queue-row-\(row.episodeID)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .queued, .awaitingConsent:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .capDeferred:
            Image(systemName: "hourglass")
                .foregroundStyle(.secondary)
        case .interrupted:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
        }
    }
}
