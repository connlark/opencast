import SwiftUI

struct EpisodeNotificationCardView: View {
    let viewModel: EpisodeNotificationViewModel

    @ScaledMetric(relativeTo: .body) private var horizontalPadding: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var topPadding: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var bottomPadding: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 102
    @ScaledMetric(relativeTo: .body) private var topRowSpacing: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var metadataFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .title3) private var episodeTitleFontSize: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var scaledSummaryTopSpacing: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var summaryFontSize: CGFloat = 19

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: topRowSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.podcastTitle.uppercased())
                        .font(.system(size: metadataFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(viewModel.episodeTitle)
                        .font(.system(size: episodeTitleFontSize, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)

                    if let durationText = viewModel.durationText {
                        Text(durationText)
                            .font(.system(size: metadataFontSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                EpisodeNotificationArtworkView(
                    image: viewModel.artworkImage,
                    initials: viewModel.podcastInitials,
                    size: artworkSize
                )
            }

            if let summaryText = viewModel.summaryText {
                Text(summaryText)
                    .font(.system(size: summaryFontSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .padding(.top, summaryTopSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.accessibilityLabel)
    }

    private var summaryTopSpacing: CGFloat {
        min(scaledSummaryTopSpacing, 52)
    }
}

#Preview {
    EpisodeNotificationCardView(
        viewModel: EpisodeNotificationViewModel.preview
    )
}
