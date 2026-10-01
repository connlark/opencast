import SwiftUI

/// A smart rule chip's visible label: the tinted glyph and the current value
/// in primary text on a glass capsule. The capsule stays text-sized; the
/// 44 pt frame outside the glass is what takes the tap, because a `.glass`
/// button style around a 44 pt label draws a taller capsule. At accessibility
/// sizes a long value wraps instead of truncating, and the glass becomes a
/// rounded rectangle so the glyph stays inside it.
struct PlaylistRuleChipLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: glassShape)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private var glassShape: AnyShape {
        dynamicTypeSize.isAccessibilitySize
            ? AnyShape(RoundedRectangle(cornerRadius: 22))
            : AnyShape(Capsule())
    }
}

extension View {
    /// The chip menu's style and accessibility: "<Clause>, <value>" as the
    /// label, both words for Voice Control, and "Smart Rule <Clause>" as the
    /// identifier. `accessibilityTitle` is the spoken value when the visible
    /// one abbreviates ("Under 45 minutes").
    func smartRuleChipMenu(clause: String, title: String, accessibilityTitle: String? = nil) -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("\(clause), \(accessibilityTitle ?? title)")
            .accessibilityInputLabels([clause, title])
            .accessibilityIdentifier("Smart Rule \(clause)")
    }
}
