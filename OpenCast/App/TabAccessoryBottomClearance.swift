import SwiftUI

/// Measured against this scroll view's own frame, which SwiftUI keeps inside
/// the safe area, so the proxy's safe-area insets are not subtracted again.
/// Outside the tab view, and in a sheet, there is no store and no margin.
struct TabAccessoryBottomClearance: ViewModifier {
    @Environment(TabAccessoryGeometryStore.self) private var accessoryStore: TabAccessoryGeometryStore?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var viewport: CGRect?

    /// Nil for a List: the shell's row gap.
    let rowSpacing: Double?

    func body(content: Content) -> some View {
        let accessory = accessoryStore?.geometry ?? .absent
        let spacing = rowSpacing ?? LibraryGridMetrics.rowSpacing(
            isCompact: horizontalSizeClass == .compact || verticalSizeClass == .compact
        )
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newViewport in
                viewport = newViewport
            }
            .contentMargins(.bottom, accessory.bottomClearance(over: viewport, rowSpacing: spacing), for: .scrollContent)
    }
}

extension View {
    func tabAccessoryBottomClearance(rowSpacing: Double) -> some View {
        modifier(TabAccessoryBottomClearance(rowSpacing: rowSpacing))
    }

    /// For a List, whose rows abut: the shell's row gap.
    func tabAccessoryBottomClearance() -> some View {
        modifier(TabAccessoryBottomClearance(rowSpacing: nil))
    }
}
