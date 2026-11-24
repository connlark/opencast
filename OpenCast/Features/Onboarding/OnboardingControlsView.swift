import SwiftUI

struct OnboardingControlsView: View {
    let page: OnboardingPage
    let canGoBack: Bool
    let isPrimaryBusy: Bool
    let addedShowCount: Int
    let onBack: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if addedShowCount > 0 {
                ViewThatFits(in: .horizontal) {
                    // Each side is as wide as the wider button, so the count stays centred under the page dots.
                    HStack(spacing: 0) {
                        ZStack(alignment: .leading) {
                            backButton()
                            primaryButton().hidden()
                        }
                        Spacer(minLength: 8)
                        addedShowCountText
                        Spacer(minLength: 8)
                        ZStack(alignment: .trailing) {
                            backButton().hidden()
                            primaryButton()
                        }
                    }

                    VStack(spacing: 10) {
                        addedShowCountText
                        buttons
                    }
                }
            } else {
                buttons
            }
        }
        .accessibilityIdentifier("Onboarding Controls")
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                backButton()
                Spacer()
                primaryButton()
            }

            VStack(spacing: 10) {
                primaryButton(fillsWidth: true)
                backButton(fillsWidth: true)
            }
        }
    }

    @ViewBuilder
    private func backButton(fillsWidth: Bool = false) -> some View {
        if canGoBack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
            .buttonStyle(.glass)
        }
    }

    private func primaryButton(fillsWidth: Bool = false) -> some View {
        Button(action: onPrimary) {
            Label {
                Text(page.primaryActionTitle)
            } icon: {
                if isPrimaryBusy {
                    ProgressView()
                } else {
                    Image(systemName: page.primaryActionSystemImage)
                }
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.glassProminent)
        .disabled(isPrimaryBusy)
    }

    private var addedShowCountText: some View {
        Text("^[\(addedShowCount) show](inflect: true) added")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
