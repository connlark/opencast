import OpenCastCore
import SwiftUI

struct PodcastSearchResultRow: View {
    let result: DirectoryPodcastResult
    let isSubscribed: Bool
    let isSubscribing: Bool

    init(
        result: DirectoryPodcastResult,
        isSubscribed: Bool = false,
        isSubscribing: Bool
    ) {
        self.result = result
        self.isSubscribed = isSubscribed
        self.isSubscribing = isSubscribing
    }

    var body: some View {
        DirectoryPodcastResultRow(result: result) {
            if isSubscribing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Subscribing")
            } else if isSubscribed {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Added")
            }
        }
    }
}
