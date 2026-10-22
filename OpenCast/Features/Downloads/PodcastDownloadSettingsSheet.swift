import SwiftUI

/// A show's download settings presented from its actions menu, with Done
/// in place of the back button a pushed screen has.
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
