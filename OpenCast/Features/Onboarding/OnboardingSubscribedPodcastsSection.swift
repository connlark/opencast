import SwiftData
import SwiftUI

struct OnboardingSubscribedPodcastsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let subscriptions: [SubscriptionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Podcasts")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            LazyVStack(spacing: 0) {
                ForEach(Array(subscriptions.enumerated()), id: \.element.persistentModelID) { index, subscription in
                    PodcastRowLabel(
                        title: subscription.title,
                        author: subscription.author,
                        artworkURL: appModel.library.podcastCache(for: subscription.feedURL)?.artworkURL ?? subscription.artworkURL
                    )
                    .padding(.vertical, 8)

                    if index < subscriptions.count - 1 {
                        Divider()
                            .padding(.leading, 64)
                    }
                }
            }
            .accessibilityIdentifier("Onboarding Subscribed Podcasts Section")
        }
    }
}
