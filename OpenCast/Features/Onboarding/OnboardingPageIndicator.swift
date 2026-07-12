import SwiftUI

struct OnboardingPageIndicator: View {
    let pages: [OnboardingPage]
    let selectedPage: OnboardingPage

    var body: some View {
        HStack(spacing: 10) {
            ForEach(pages) { page in
                Circle()
                    .fill(page == selectedPage ? .primary : .secondary)
                    .frame(width: 8, height: 8)
                    .opacity(page == selectedPage ? 0.9 : 0.45)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding page \((pages.firstIndex(of: selectedPage) ?? 0) + 1) of \(pages.count)")
    }
}
