import OpenCastCore
import SwiftUI

struct PodcastIndexAttributionFooter: View {
    let results: [DirectoryPodcastResult]

    var body: some View {
        if results.contains(where: { $0.sources.contains(.podcastIndex) }) {
            Link(destination: URL(string: "https://podcastindex.org")!) {
                Text("Some results provided by Podcast Index")
                    .font(.caption)
            }
        }
    }
}
