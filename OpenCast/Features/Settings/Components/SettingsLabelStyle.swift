import SwiftUI

/// Fixed-width icon column for the Settings hub; sub-screen forms keep the
/// default label style. Rows make their icons monochrome with a concrete
/// `Color.primary` on the `Label` itself: the hierarchical `.primary`
/// resolves against the row's accent tint inside a List and stays blue.
struct SettingsLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 28.0

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .frame(width: iconColumnWidth)
            configuration.title
        }
    }
}
