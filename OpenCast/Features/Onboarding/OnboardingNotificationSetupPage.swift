import SwiftUI

struct OnboardingNotificationSetupPage: View {
    let completionErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New Episode Alerts")
                        .font(.largeTitle)
                        .bold()

                    Text("Get a push when a podcast you follow publishes a new episode. You can turn this on now or later from Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                NotificationOptInView()

                VStack(alignment: .leading, spacing: 12) {
                    OnboardingPitchRow(
                        systemImage: "bell.badge.fill",
                        title: "Only new episodes",
                        message: "Alerts fire for podcasts you already follow."
                    )

                    OnboardingPitchRow(
                        systemImage: "hand.raised.fill",
                        title: "No promo noise",
                        message: "Never marketing, promotions, or recommendations."
                    )

                    OnboardingPitchRow(
                        systemImage: "lock.fill",
                        title: "No account",
                        message: "Works without email, Apple ID, or a listener profile."
                    )
                }

                if let completionErrorMessage {
                    Label(completionErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.visible)
        .accessibilityIdentifier("Notification Onboarding")
    }
}
