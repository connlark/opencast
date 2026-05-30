import SwiftUI

struct PodcastFeedAvailabilityLabel: View {
    let hasFeedURL: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var title: String {
        hasFeedURL ? "RSS feed available" : "No RSS feed"
    }

    private var systemImage: String {
        hasFeedURL ? "checkmark.circle" : "exclamationmark.circle"
    }
}
