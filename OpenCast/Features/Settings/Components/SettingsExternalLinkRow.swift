import SwiftUI

struct SettingsExternalLinkRow: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            LabeledContent {
                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } label: {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityIdentifier("Settings Row \(title)")
    }
}
