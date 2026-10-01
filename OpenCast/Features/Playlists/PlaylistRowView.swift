import SwiftUI

/// A playlist in the collection's list layout: a small cover, the name and
/// its size line.
struct PlaylistRowView: View {
    private static let artworkSide = 56.0

    let summary: PlaylistSummary
    let sources: PlaylistCoverSources

    static func accessibilityIdentifier(for playlistID: String) -> String {
        "playlist-row-\(playlistID)"
    }

    var body: some View {
        NavigationLink(value: AppRoute.playlistDetail(id: summary.playlistID)) {
            HStack(spacing: 14) {
                PlaylistCoverView(summary: summary, sources: sources, cornerRadius: 8)
                    .frame(width: Self.artworkSide, height: Self.artworkSide)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(2)
                    PlaylistSummaryLine(summary: summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier(Self.accessibilityIdentifier(for: summary.playlistID))
    }
}
