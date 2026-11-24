import OpenCastCore
import SwiftUI

struct PodcastPreviewLoadingContent: View {
    private static let placeholderEpisodes = [
        "A placeholder for the newest episode title",
        "A shorter placeholder title",
        "Another placeholder episode title here",
    ].enumerated().map { index, title in
        Episode(
            id: EpisodeID(rawValue: "placeholder-\(index)"),
            podcastID: PodcastID(rawValue: "placeholder"),
            podcastTitle: "",
            title: title,
            duration: 1_440
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily · Newest today")
                            .font(.footnote.weight(.semibold))
                        Text("1,412 episodes")
                            .font(.footnote)
                    }
                    .redacted(reason: .placeholder)

                    Spacer(minLength: 8)

                    PodcastReleaseRhythmChart(counts: Array(repeating: 2, count: 12), ceiling: 5)
                        .tint(.secondary.opacity(0.22))
                        .frame(width: 108, height: 30)
                }
                Text(String(repeating: "A placeholder for the show’s description. ", count: 4))
                    .font(.subheadline)
                    .lineLimit(3)
                    .redacted(reason: .placeholder)
            }

            PodcastPreviewEpisodeList(episodes: Self.placeholderEpisodes, isExpanded: false)
                .redacted(reason: .placeholder)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
