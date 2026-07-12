import SwiftUI

struct OnboardingApplePodcastsShortcutDisclosure: View {
    @Environment(\.openURL) private var openURL
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This iCloud Shortcut helps export your Apple Podcasts subscriptions into an OPML file that opencast can import.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Button("Open Shortcut", systemImage: "link", action: openShortcut)
                    .buttonStyle(.glass)
            }
            .padding(.top, 8)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Podcasts Export Shortcut")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Use a Shortcut to make an OPML file from Apple Podcasts.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "link")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .frame(width: 28, alignment: .center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("Apple Podcasts Export Shortcut")
        }
        .buttonStyle(.plain)
        .tint(.primary)
    }

    private func openShortcut() {
        openURL(OpenCastConstants.applePodcastsOPMLShortcutURL)
    }
}
