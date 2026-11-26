import OpenCastCore
import SwiftUI

struct PodcastPreviewPagedEpisodeList: View {
    private static let pageSize = 100

    @State private var shownCount = Self.pageSize

    let episodes: [FeedDigest.EpisodeLine]

    var body: some View {
        PodcastPreviewEpisodeList(episodes: episodes.prefix(shownCount))

        if shownCount < episodes.count {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Button(action: showMore) {
                    Label("Show More Episodes", systemImage: "chevron.down")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .font(.subheadline)
                .bold()
                .buttonStyle(.plain)
            }
        }
    }

    private func showMore() {
        shownCount += Self.pageSize
    }
}
