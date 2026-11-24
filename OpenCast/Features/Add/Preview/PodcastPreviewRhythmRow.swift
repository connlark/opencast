import SwiftUI

struct PodcastPreviewRhythmRow: View {
    let feeds: PodcastPreviewFeeds
    @Binding var selectedFeedID: String?
    let isInLibrary: Bool

    var body: some View {
        let feed = feeds.feed(id: selectedFeedID)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                lines(feed)
                    .lineLimit(1)

                Spacer(minLength: 8)

                chart(feed)
            }

            VStack(alignment: .leading, spacing: 8) {
                lines(feed)
                chart(feed)
            }
        }
    }

    private func lines(_ feed: PodcastPreviewFeed) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let rhythm = PodcastPreviewText.rhythmLine(feed.digest) {
                Text(rhythm)
                    .font(.footnote.weight(.semibold))
            }
            if feeds.other == nil || isInLibrary {
                Text(PodcastPreviewText.countLine(feed))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                PodcastPreviewFeedMenu(feeds: feeds, selectedFeedID: $selectedFeedID)
            }
        }
    }

    private func chart(_ feed: PodcastPreviewFeed) -> some View {
        PodcastReleaseRhythmChart(counts: feed.digest.monthlyEpisodeCounts)
            .frame(width: 108, height: 30)
    }
}
