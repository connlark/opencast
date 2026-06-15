import SwiftUI

struct InboxLoadingStateView: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Inbox")
        .accessibilityIdentifier("Inbox Loading")
    }
}
