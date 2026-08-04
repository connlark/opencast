import SwiftUI

/// Shown when a feed's refreshes keep landing on a different host: offers the
/// migration instead of performing it automatically, since redirects are
/// routinely CDN noise.
struct FeedAddressUpdateView: View {
    let suggestedFeedURL: URL
    let onUpdate: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Label(
                "This feed now redirects to \(suggestedFeedURL.host ?? "a new address").",
                systemImage: "arrow.triangle.branch"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button("Update Feed Address", action: onUpdate)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
