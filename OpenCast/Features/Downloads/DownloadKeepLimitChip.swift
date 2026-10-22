import SwiftUI

/// A show's resolved Keep Downloaded limit as a small capsule ("Keep 3",
/// "No limit") beside its storage figures.
struct DownloadKeepLimitChip: View {
    let keepLimit: DownloadKeepLimit

    var body: some View {
        Text(keepLimit.shortTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: .capsule)
            .accessibilityLabel("Keep Downloaded, \(keepLimit.title)")
    }
}
