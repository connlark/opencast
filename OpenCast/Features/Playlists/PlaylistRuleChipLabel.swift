import SwiftUI

/// The 44 pt tap frame sits outside the glass: a `.glass` button style around a 44 pt label
/// draws a taller capsule.
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
    /// `accessibilityTitle` is the spoken value when the visible one abbreviates.
    func smartRuleChipMenu(clause: String, title: String, accessibilityTitle: String? = nil) -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("\(clause), \(accessibilityTitle ?? title)")
            .accessibilityInputLabels([clause, title])
            .accessibilityIdentifier("Smart Rule \(clause)")
    }
}
