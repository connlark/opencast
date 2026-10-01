import SwiftUI

/// A playlist item whose episode no longer resolves, drawn from the title,
/// show and artwork the item kept when it was added. It cannot play; the only
/// action is removing it.
struct PlaylistUnavailableRowView: View {
    let item: PlaylistItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkPlaceholder(
                title: item.podcastTitle,
                imageURL: item.artworkURL,
                size: 56,
                cacheKind: .episode
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.episodeTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(item.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Label("No longer in your library", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(PlaylistEpisodeRowView.accessibilityIdentifier(for: item.itemID))
    }
}
