import SwiftUI

struct EpisodeRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let episode: EpisodeListItemSnapshot
    var searchResult: EpisodeSearchResult?

    static func accessibilityIdentifier(for episodeID: String) -> String {
        "episode-row-\(episodeID)"
    }

    var body: some View {
        let progressSummary = appModel.library.progressSummary(for: episode)

        HStack(alignment: .top, spacing: 12) {
            ArtworkPlaceholder(
                title: episode.podcastTitle,
                imageURL: episode.artworkURL,
                size: 56,
                cacheKind: .episode,
                preview: episode.artworkPreview,
                onPreviewResolved: updateArtworkPreview
            )

            VStack(alignment: .leading, spacing: 6) {
                if let searchResult {
                    Text(searchResult.highlightedTitle)
                        .font(.headline)
                        .lineLimit(2)
                } else {
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(2)
                }
                if let searchResult {
                    Text(searchResult.highlightedPodcastTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                } else {
                    Text(episode.podcastTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let publishedAt = episode.publishedAt {
                        Text(publishedAt, format: .dateTime.month(.abbreviated).day().year())
                    }
                    if let duration = episode.duration {
                        Text(duration.formattedPlaybackDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if progressSummary.hasVisibleProgress {
                    VStack(alignment: .leading, spacing: 5) {
                        if progressSummary.duration != nil {
                            EpisodeProgressBarView(fractionCompleted: progressSummary.fractionCompleted)
                                .frame(maxWidth: 280)
                        }

                        if let remainingText = progressSummary.remainingText {
                            Text(remainingText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }

                if let snippet = searchResult?.snippet {
                    Text(snippet)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusIcon(for: progressSummary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: progressSummary)
        .accessibilityValue(progressSummary.accessibilityDescription)
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        appModel.library.updateArtworkPreview(preview, for: episode)
    }

    private func statusIcon(for progressSummary: EpisodeProgressSummary) -> some View {
        Image(systemName: progressSummary.isCompleted ? "checkmark.circle.fill" : "play.circle")
            .font(.title2)
            .foregroundStyle(
                progressSummary.isCompleted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint)
            )
            .frame(width: 34, height: 34)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
