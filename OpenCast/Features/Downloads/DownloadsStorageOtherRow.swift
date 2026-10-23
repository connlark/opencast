import SwiftUI

/// Other's legend entry: the shows past the bar's fifth segment, listed
/// when expanded.
struct DownloadsStorageOtherRow: View {
    let segment: DownloadsStorageGraphSegment
    let onDelete: (DownloadsPodcastBreakdown) -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(segment.members) { breakdown in
                DownloadsStorageLegendRow(
                    breakdown: breakdown,
                    segment: nil,
                    onDelete: { onDelete(breakdown) }
                )
            }
        } label: {
            HStack(spacing: 12) {
                DownloadsStorageLegendMarker(segment: segment)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Other")
                    Text(
                        "\(segment.members.count) shows · \(DownloadsStorageText.showDetail(episodeCount: segment.episodeCount, byteCount: segment.byteCount))"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            // On the label: an identifier on the group would also replace
            // the identifiers of the shows it lists.
            .accessibilityIdentifier("downloads-storage-other")
        }
    }
}
