import SwiftUI

struct OnboardingControlsView: View {
    let page: OnboardingPage
    let canGoBack: Bool
    let isPrimaryDisabled: Bool
    let onBack: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack {
                if canGoBack {
                    Button("Back", systemImage: "chevron.left", action: onBack)
                        .buttonStyle(.glass)
                }

                Spacer()

                Button(page.primaryActionTitle, systemImage: page.primaryActionSystemImage, action: onPrimary)
                    .buttonStyle(.glassProminent)
                    .disabled(isPrimaryDisabled)
            }
        }
        .accessibilityIdentifier("Onboarding Controls")
    }
}
