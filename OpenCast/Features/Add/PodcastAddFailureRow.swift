import SwiftUI

struct PodcastAddFailureRow: View {
    let failure: DirectorySubscriptionFlowStore.Failure
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn’t Subscribe to \(failure.showTitle)")
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onDismiss) {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
        }
    }
}
