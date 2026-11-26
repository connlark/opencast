import SwiftUI

struct PodcastPreviewLoadedContent: View {
    let feeds: PodcastPreviewFeeds
    @Binding var selectedFeedID: String?
    let isInLibrary: Bool
    let listsEveryEpisode: Bool

    var body: some View {
        let feed = feeds.feed(id: selectedFeedID)

        VStack(alignment: .leading, spacing: 8) {
            PodcastPreviewRhythmRow(feeds: feeds, selectedFeedID: $selectedFeedID, isInLibrary: isInLibrary)
            if !feed.description.isEmpty {
                PodcastDescriptionView(summary: feed.description)
                    .id(feed.id)
            }
        }

        if listsEveryEpisode {
            PodcastPreviewPagedEpisodeList(episodes: feed.digest.episodes)
                .id(feed.id)
        } else {
            PodcastPreviewEpisodeList(episodes: feed.digest.episodes.prefix(3))
        }
    }
}
