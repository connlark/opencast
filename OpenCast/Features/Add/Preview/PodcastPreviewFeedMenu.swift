import SwiftUI

struct PodcastPreviewFeedMenu: View {
    let feeds: PodcastPreviewFeeds
    @Binding var selectedFeedID: String?

    var body: some View {
        Menu {
            Picker("Feed", selection: $selectedFeedID) {
                ForEach(feeds.all) { feed in
                    Text(PodcastPreviewText.feedMenuTitle(feed, in: feeds))
                        .tag(Optional(feed.id))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(PodcastPreviewText.feedMenuTitle(feeds.feed(id: selectedFeedID), in: feeds))
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(.footnote)
        }
    }
}
