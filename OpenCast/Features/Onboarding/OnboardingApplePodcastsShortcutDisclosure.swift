import SwiftUI

struct OnboardingApplePodcastsShortcutDisclosure: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Apple Podcasts Export Shortcut", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This iCloud Shortcut helps export your Apple Podcasts subscriptions into an OPML file that opencast can import.")
                    .foregroundStyle(.secondary)

                Link(destination: OpenCastConstants.applePodcastsOPMLShortcutURL) {
                    Label("Open Shortcut", systemImage: "link")
                }
            }
            .padding(.top, 8)
        }
    }
}
