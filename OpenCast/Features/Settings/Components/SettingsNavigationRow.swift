import SwiftUI

struct SettingsNavigationRow: View {
    let title: String
    let systemImage: String
    let route: SettingsRoute
    var value: String?

    var body: some View {
        NavigationLink(value: AppRoute.settings(route)) {
            LabeledContent {
                if let value {
                    Text(value)
                }
            } label: {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityIdentifier("Settings Row \(title)")
    }
}
