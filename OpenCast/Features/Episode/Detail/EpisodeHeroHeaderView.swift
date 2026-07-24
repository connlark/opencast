import SwiftUI

struct EpisodeHeroHeaderView: View {
    let episode: EpisodeListItemSnapshot
    let chips: [EpisodeMetadataChip]
    let onPreviewResolved: (ArtworkPreview) -> Void

    @State private var artworkLength: CGFloat = 220

    var body: some View {
        VStack(spacing: 14) {
            NavigationLink(value: AppRoute.episodeArtwork(id: episode.episodeID)) {
                ArtworkPlaceholder(
                    title: episode.podcastTitle,
                    imageURL: episode.artworkURL,
                    size: artworkLength,
                    cacheKind: .episode,
                    preview: episode.artworkPreview,
                    onPreviewResolved: onPreviewResolved
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View Episode Artwork")
            .accessibilityHint("Opens a zoomable artwork view")
            .accessibilityIdentifier("Episode Artwork")

            VStack(spacing: 6) {
                Text(episode.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(episode.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            if !chips.isEmpty {
                EpisodeMetadataChipsRow(chips: chips)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            artworkLength = min(max(width * 0.6, 120), 340)
        }
    }
}

#Preview("Dark") {
    ScrollView {
        EpisodeHeroHeaderView(
            episode: .previewSample,
            chips: [
                .publishDate(Date(timeIntervalSince1970: 1_780_000_000)),
                .duration("2h 47m"),
                .downloaded(fileSize: "42 MB")
            ],
            onPreviewResolved: { _ in }
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    ScrollView {
        EpisodeHeroHeaderView(
            episode: .previewSample,
            chips: [
                .publishDate(Date(timeIntervalSince1970: 1_780_000_000)),
                .remaining("2h 47m left", fractionCompleted: 0.3)
            ],
            onPreviewResolved: { _ in }
        )
        .padding()
    }
    .preferredColorScheme(.light)
}
