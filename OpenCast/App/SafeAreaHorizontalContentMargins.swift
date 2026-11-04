import SwiftUI

/// A List's regular-width horizontal margin, counted from the safe area's
/// edge, never the window's. A List's explicit content margins replace its
/// safe-area-aware layout margins and count from the scroll view's edge (A4,
/// Open landscape: the Inbox rows ran 52 pt into the rail's 84 pt inset), so
/// the List's own horizontal safe-area insets are added back. Compact width
/// keeps the system's margins. A ScrollView's content margins already add to
/// its safe area and need none of this.
struct SafeAreaHorizontalContentMargins: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var safeAreaInsets = EdgeInsets()

    let regularMargin: Double

    func body(content: Content) -> some View {
        let margins = Self.margins(
            regularMargin: regularMargin,
            isRegularWidth: horizontalSizeClass == .regular,
            safeAreaInsets: safeAreaInsets
        )
        content
            .onGeometryChange(for: EdgeInsets.self) { proxy in
                proxy.safeAreaInsets
            } action: { insets in
                safeAreaInsets = insets
            }
            .contentMargins(.leading, margins.leading, for: .scrollContent)
            .contentMargins(.trailing, margins.trailing, for: .scrollContent)
    }

    /// Nil at compact width: the system's margins. `CGFloat` because a
    /// content margin takes an optional length.
    nonisolated static func margins(
        regularMargin: Double,
        isRegularWidth: Bool,
        safeAreaInsets: EdgeInsets
    ) -> (leading: CGFloat?, trailing: CGFloat?) {
        guard isRegularWidth else {
            return (nil, nil)
        }
        return (safeAreaInsets.leading + regularMargin, safeAreaInsets.trailing + regularMargin)
    }
}

extension View {
    func safeAreaHorizontalContentMargins(regular regularMargin: Double) -> some View {
        modifier(SafeAreaHorizontalContentMargins(regularMargin: regularMargin))
    }
}
