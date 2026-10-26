import SwiftUI

/// A provider chip's visible label on a glass capsule, the same shape as the
/// smart playlist rule chips: the capsule stays text-sized and the 44 pt
/// frame outside the glass takes the tap. At accessibility sizes the glass
/// becomes a rounded rectangle so a wrapped label stays inside it. The
/// label style is set by the container: set inside a menu label, it crashed
/// SwiftUI on iOS 27.
struct AnalysisProviderChipLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let isInteractive: Bool

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(isInteractive ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
        } icon: {
            Image(systemName: "cpu")
                .foregroundStyle(isInteractive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        .lineLimit(2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(isInteractive), in: glassShape)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private var glassShape: AnyShape {
        dynamicTypeSize.isAccessibilitySize
            ? AnyShape(RoundedRectangle(cornerRadius: 22))
            : AnyShape(Capsule())
    }
}
