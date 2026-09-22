import SwiftUI

/// Count badge on a Library grid tile's artwork. Decorative: the tile's link
/// carries the spoken value, so the badge stays out of the accessibility
/// tree instead of reading the number twice.
struct LibraryNewEpisodeBadge: View {
    static let displayLimit = 99

    let count: Int

    var body: some View {
        Group {
            if count > Self.displayLimit {
                Text("\(Self.displayLimit)+")
            } else {
                Text(count, format: .number)
            }
        }
        .font(.caption.bold())
        // Grows with text size, but stops before it hides the artwork; the
        // link's spoken value carries the exact count.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minWidth: 20)
        .background(.red, in: .capsule)
        .accessibilityHidden(true)
    }

    /// The link value rows and tiles share; empty when there is nothing new.
    static func accessibilityValue(count: Int) -> Text {
        count > 0 ? Text("^[\(count) new episode](inflect: true)") : Text(verbatim: "")
    }
}
