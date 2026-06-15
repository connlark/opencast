import SwiftUI

struct InboxFailedStateView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Inbox Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("Inbox Unavailable")
    }
}
