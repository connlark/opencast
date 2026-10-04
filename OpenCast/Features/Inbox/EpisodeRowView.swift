import SwiftUI

struct EpisodeRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let episode: EpisodeListItemSnapshot
    var searchResult: EpisodeSearchResult?
    var showsLocalStatusBadges = false
    var onPlay: (() -> Void)?

    static func accessibilityIdentifier(for episodeID: String) -> String {
        "episode-row-\(episodeID)"
    }

    static func playAccessibilityIdentifier(for episodeID: String) -> String {
        "episode-play-\(episodeID)"
    }

    var body: some View {
        let progressSummary = appModel.library.progressSummary(for: episode)

        HStack(alignment: .top, spacing: 12) {
            ArtworkPlaceholder(
                title: episode.podcastTitle,
                imageURL: episode.artworkURL,
                size: 56,
                cacheKind: .episode,
                preview: appModel.library.artworkPreview(for: episode),
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
                    if showsLocalStatusBadges {
                        EpisodeLocalStatusBadgesView(episodeID: episode.episodeID)
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

    @ViewBuilder
    private func statusIcon(for progressSummary: EpisodeProgressSummary) -> some View {
        if let onPlay {
            // The frame and content shape sit inside the label so the whole
            // 44-point square is the button's hit area, not just the glyph.
            Button(action: onPlay) {
                Label(
                    progressSummary.isCompleted ? "Play Again" : "Play",
                    systemImage: statusSystemImage(for: progressSummary)
                )
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(statusStyle(for: progressSummary))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(Self.playAccessibilityIdentifier(for: episode.episodeID))
        } else {
            Image(systemName: statusSystemImage(for: progressSummary))
                .font(.title2)
                .foregroundStyle(statusStyle(for: progressSummary))
                .frame(width: 34, height: 34)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
    }

    private func statusSystemImage(for progressSummary: EpisodeProgressSummary) -> String {
        progressSummary.isCompleted ? "checkmark.circle.fill" : "play.circle"
    }

    private func statusStyle(for progressSummary: EpisodeProgressSummary) -> AnyShapeStyle {
        progressSummary.isCompleted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint)
    }
}
