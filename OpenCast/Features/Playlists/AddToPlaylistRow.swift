import SwiftUI

/// One manual playlist in the Add to Playlist picker. The whole row is a
/// single toggle: a filled check when the playlist holds the episode, an
/// empty ring when it does not.
struct AddToPlaylistRow: View {
    let summary: PlaylistSummary
    let sources: PlaylistCoverSources
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PlaylistArtworkMosaic(sources: sources, cornerRadius: 8)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                    PlaylistSummaryText(itemCount: summary.itemCount, totalDuration: summary.totalDuration)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Removes the episode" : "Adds the episode")
        .accessibilityIdentifier("add-to-playlist-row-\(summary.playlistID)")
    }
}
