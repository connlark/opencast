import SwiftUI

/// The quiet count a Library list row shows before its status icons.
/// Decorative for the same reason as `LibraryNewEpisodeBadge`.
struct LibraryNewEpisodeCountLabel: View {
    let count: Int

    var body: some View {
        Group {
            if count > LibraryNewEpisodeBadge.displayLimit {
                Text("\(LibraryNewEpisodeBadge.displayLimit)+")
            } else {
                Text(count, format: .number)
            }
        }
        .font(.subheadline)
        // Capped like the grid badge so the pill can't crowd out the title.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.fill.tertiary, in: .capsule)
        .accessibilityHidden(true)
    }
}
