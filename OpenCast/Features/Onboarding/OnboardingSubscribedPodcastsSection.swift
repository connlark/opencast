import SwiftData
import SwiftUI

struct OnboardingSubscribedPodcastsSection: View {
    let subscriptions: [SubscriptionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Podcasts")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(Array(subscriptions.enumerated()), id: \.element.persistentModelID) { index, subscription in
                    SubscriptionRowView(subscription: subscription)

                    if index < subscriptions.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .accessibilityIdentifier("Onboarding Subscribed Podcasts Section")
        }
    }
}
