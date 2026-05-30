import OpenCastCore
import SwiftUI

struct DirectoryPodcastResultRow<TrailingContent: View>: View {
    let result: DirectoryPodcastResult
    let trailingContent: () -> TrailingContent

    init(
        result: DirectoryPodcastResult,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.result = result
        self.trailingContent = trailingContent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkPlaceholder(title: result.title, imageURL: result.artworkURL?.absoluteString, size: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)

                if let artistName = result.artistName, !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                PodcastFeedAvailabilityLabel(hasFeedURL: result.feedURLString != nil)
            }

            Spacer(minLength: 8)

            trailingContent()
        }
        .padding(.vertical, 4)
    }
}
