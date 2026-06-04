import SwiftUI

struct InboxEmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label("Inbox Empty", systemImage: "tray")
            } description: {
                Text("Episodes appear here after you subscribe to a podcast.")
            }

            Button(action: onAdd) {
                Text("Add Podcast")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("Inbox Empty Add Podcast")
        }
        .frame(maxWidth: .infinity)
    }
}
