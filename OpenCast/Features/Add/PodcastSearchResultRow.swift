import OpenCastCore
import SwiftUI

struct PodcastSearchResultRow: View {
    let result: DirectoryPodcastResult
    let isSubscribing: Bool

    var body: some View {
        DirectoryPodcastResultRow(result: result) {
            if isSubscribing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Subscribing")
            }
        }
    }
}
