import SwiftUI

/// Applied to each tab's content, inside the tab view, where the system
/// reports the bar's placement: publishes it to the tab's screens.
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
