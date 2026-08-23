import SwiftUI

struct PodcastFeedAvailabilityLabel: View {
    let canResolveFeed: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var title: String {
        canResolveFeed ? "RSS feed available" : "No RSS feed"
    }

    private var systemImage: String {
        canResolveFeed ? "checkmark.circle" : "exclamationmark.circle"
    }
}
