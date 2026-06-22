import SwiftUI

struct ImportedSubscriptionsNotificationBanner: View {
    let notification: ImportedSubscriptionsNotification

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.headline)

                Text(notification.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "checkmark.icloud.fill")
                .font(.title3)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Imported Subscriptions Notification")
    }
}
