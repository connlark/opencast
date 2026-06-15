import SwiftUI

struct EpisodeContextPreviewView: View {
    let episode: EpisodeListItemSnapshot

    @State private var summaryText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkPlaceholder(
                    title: episode.podcastTitle,
                    imageURL: episode.artworkURL,
                    size: 72,
                    cacheKind: .episode,
                    preview: episode.artworkPreview
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(3)
                    Text(episode.podcastTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            if let summaryText {
                Text(summaryText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Episode summary")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .redacted(reason: .placeholder)
            }
        }
        .padding()
        .frame(idealWidth: 360, maxWidth: 420, alignment: .leading)
        .accessibilityIdentifier("Episode Context Preview")
        .task {
            let textContent = await EpisodeTextContent.resolving(
                summaryHTML: episode.summary,
                showNotesHTML: nil
            )
            guard !Task.isCancelled else {
                return
            }

            summaryText = textContent.summary
        }
    }

    private var metadataText: String {
        var parts: [String] = []
        if let publishedAt = episode.publishedAt {
            parts.append(publishedAt.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        if let duration = episode.duration {
            parts.append(duration.formattedPlaybackDuration)
        }

        return parts.joined(separator: " - ")
    }
}
