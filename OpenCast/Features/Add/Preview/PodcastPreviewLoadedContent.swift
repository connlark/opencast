import SwiftUI

struct PodcastPreviewLoadedContent: View {
    let feeds: PodcastPreviewFeeds
    @Binding var selectedFeedID: String?
    let isInLibrary: Bool
    let isExpanded: Bool

    var body: some View {
        let feed = feeds.feed(id: selectedFeedID)

        VStack(alignment: .leading, spacing: 8) {
            PodcastPreviewRhythmRow(feeds: feeds, selectedFeedID: $selectedFeedID, isInLibrary: isInLibrary)
            if !feed.description.isEmpty {
                Text(feed.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        PodcastPreviewEpisodeList(
            episodes: Array(feed.digest.newestEpisodes.prefix(isExpanded ? PodcastPreviewFeed.newestEpisodeLimit : 3)),
            isExpanded: isExpanded
        )
    }
}
