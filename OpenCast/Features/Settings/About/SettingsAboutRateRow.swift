import StoreKit
import SwiftUI

/// The system's in-app review sheet, so rating never leaves the app. The
/// system decides whether to show it (at most three times a year in
/// production, never in TestFlight), so a tap can legitimately do nothing.
struct SettingsAboutRateRow: View {
    var body: some View {
        Button(action: rate) {
            Label("Rate opencast", systemImage: "star")
                .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("Settings Row Rate opencast")
    }

    /// `AppStore.requestReview(in:)` rather than the `requestReview`
    /// environment value: that value lives in the `_StoreKit_SwiftUI`
    /// overlay, and linking it loads dozens of extra system images at launch.
    private func rate() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else {
            return
        }
        AppStore.requestReview(in: scene)
    }
}
