import SwiftUI

/// A playlist in the collection's grid layout, sized by the same metrics as
/// the Library's show tiles so both grids line up.
struct PlaylistTileView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let summary: PlaylistSummary
    let sources: PlaylistCoverSources
    let metrics: LibraryGridMetrics

    var body: some View {
        NavigationLink(value: AppRoute.playlistDetail(id: summary.playlistID)) {
            VStack(alignment: .leading, spacing: metrics.isCompact ? 6 : 10) {
                PlaylistCoverView(summary: summary, sources: sources, cornerRadius: 12)
                    .frame(width: metrics.tileWidth, height: metrics.tileWidth)
                    .overlay(alignment: .topLeading) {
                        if let tint = summary.tint {
                            PlaylistSmartBadge(tint: tint)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    PlaylistSummaryLine(summary: summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(PlaylistRowView.accessibilityIdentifier(for: summary.playlistID))
    }
}
