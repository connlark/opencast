import OpenCastCore
import SwiftUI

struct PodcastPreviewEpisodeList: View {
    let episodes: [Episode]
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(episodes) { episode in
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title)
                            .font(.subheadline)
                            .bold()
                            .lineLimit(isExpanded ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PodcastPreviewText.episodeCaption(episode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
