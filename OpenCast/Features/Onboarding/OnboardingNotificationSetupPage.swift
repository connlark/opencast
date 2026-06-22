import SwiftUI

struct OnboardingNotificationSetupPage: View {
    let completionErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get New Episode Alerts")
                        .font(.largeTitle)
                        .bold()

                    Text("opencast can watch your subscribed RSS feeds and send a push when a new episode appears.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                NotificationOptInView()

                if let completionErrorMessage {
                    Label(completionErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.visible)
        .accessibilityIdentifier("Notification Onboarding")
    }
}
