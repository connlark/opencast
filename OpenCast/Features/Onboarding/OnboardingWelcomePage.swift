import SwiftUI

struct OnboardingWelcomePage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Welcome to opencast!")
                        .font(.largeTitle)
                        .bold()

                    Text("A small, native podcast app for RSS feeds, iCloud-synced subscriptions, and playback without the ad-tech baggage.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    OnboardingPitchRow(
                        systemImage: "eye.slash",
                        title: "No third-party analytics",
                        message: "Your listening is not a growth funnel."
                    )

                    OnboardingPitchRow(
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        title: "View Source on GitHub",
                        message: "MIT-licensed code and project history are public.",
                        destination: OpenCastConstants.sourceCodeURL
                    )

                    OnboardingPitchRow(
                        systemImage: "shippingbox",
                        title: "Tiny install",
                        message: "Built to stay around 3 MB."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollContentBackground(.visible)
    }
}
