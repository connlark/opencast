import SwiftUI

struct PodcastDownloadSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let feedURL: String

    var body: some View {
        NavigationStack {
            PodcastDownloadSettingsView(feedURL: feedURL)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
    }
}
