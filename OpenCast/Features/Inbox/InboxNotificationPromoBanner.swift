import SwiftUI

struct InboxNotificationPromoBanner: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable New Episode Alerts")
                            .font(.headline)

                        Text("Open Settings to turn on pushes when subscribed feeds publish a new episode.")
                            .font(.subheadline)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Inbox Notification Promo Banner")

            Button("Dismiss Notification Promo", systemImage: "xmark", action: onDismiss)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("Dismiss Notification Promo")
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.blue.gradient, in: .rect(cornerRadius: 18))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
