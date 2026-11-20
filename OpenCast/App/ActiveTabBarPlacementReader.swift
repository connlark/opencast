import SwiftUI

/// Must sit inside each tab's content: only there does the system report the
/// bar's placement.
struct ActiveTabBarPlacementReader: ViewModifier {
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
        content.environment(
            \.activeTabBarPlacement,
            ActiveTabBarPlacement(tabBarPlacement: tabBarPlacement, toolbarVerticalEdge: toolbarVerticalEdge)
        )
    }
}

extension View {
    func publishesActiveTabBarPlacement() -> some View {
        modifier(ActiveTabBarPlacementReader())
    }
}
