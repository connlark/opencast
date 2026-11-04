import SwiftUI

/// A scroll view's bottom content margin for the tab accessory, derived from
/// the accessory's published geometry against this scroll view's own frame,
/// which SwiftUI keeps inside the safe area: the system-adjusted viewport
/// (`TabAccessoryGeometry.bottomClearance(over:rowSpacing:)`). Its proxy's
/// safe-area insets lie outside that frame, where the content only scrolls
/// through, so they are not subtracted again. The last row rests one row gap
/// above the accessory: the consumer's own row spacing, or for a List, whose
/// rows abut, the shell's row gap for the width class
/// (`LibraryGridMetrics.rowSpacing(isCompact:)`). It replaces the fixed
/// per-screen margins, which assumed a bottom bar. Outside the tab view, and
/// in a sheet, there is no store and no margin.
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
    /// For a scroll view whose rows are `rowSpacing` apart.
    func tabAccessoryBottomClearance(rowSpacing: Double) -> some View {
        modifier(TabAccessoryBottomClearance(rowSpacing: rowSpacing))
    }

    /// For a List, whose rows abut: the shell's row gap.
    func tabAccessoryBottomClearance() -> some View {
        modifier(TabAccessoryBottomClearance(rowSpacing: nil))
    }
}
