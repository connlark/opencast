import SwiftUI

/// A List's explicit content margins replace its safe-area-aware layout
/// margins and count from the scroll view's edge, so the List's horizontal
/// safe-area insets are added back. A ScrollView needs none of this.
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

    /// nil keeps the system's margins.
    private nonisolated static func margins(
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
