import SwiftUI
import Testing
@testable import OpenCast

@Suite("Active tab bar placement")
struct ActiveTabBarPlacementTests {
    @Test("Any vertical-bar edge is a rail, whatever the tab bar placement reads", arguments: [HorizontalEdge.leading, .trailing])
    func verticalEdgeIsRail(edge: HorizontalEdge) {
        #expect(ActiveTabBarPlacement(tabBarPlacement: .bottomBar, toolbarVerticalEdge: edge) == .rail)
        #expect(ActiveTabBarPlacement(tabBarPlacement: .topBar, toolbarVerticalEdge: edge) == .rail)
        #expect(ActiveTabBarPlacement(tabBarPlacement: .sidebar, toolbarVerticalEdge: edge) == .rail)
        #expect(ActiveTabBarPlacement(tabBarPlacement: nil, toolbarVerticalEdge: edge) == .rail)
    }

    @Test("Without a vertical bar the tab bar placement decides")
    func placementWithoutVerticalBar() {
        #expect(ActiveTabBarPlacement(tabBarPlacement: .bottomBar, toolbarVerticalEdge: nil) == .bottomBar)
        #expect(ActiveTabBarPlacement(tabBarPlacement: .topBar, toolbarVerticalEdge: nil) == .topBar)
        #expect(ActiveTabBarPlacement(tabBarPlacement: .sidebar, toolbarVerticalEdge: nil) == .sidebar)
        #expect(ActiveTabBarPlacement(tabBarPlacement: nil, toolbarVerticalEdge: nil) == nil)
        #expect(ActiveTabBarPlacement(tabBarPlacement: .ornament, toolbarVerticalEdge: nil) == nil)
        #expect(ActiveTabBarPlacement(tabBarPlacement: .pageIndicator, toolbarVerticalEdge: nil) == nil)
    }

    @Test("Only a bottom bar offers minimize on scroll")
    func onlyBottomBarMinimizes() {
        #expect(ActiveTabBarPlacement.bottomBar.minimizesOnScroll)
        #expect(!ActiveTabBarPlacement.rail.minimizesOnScroll)
        #expect(!ActiveTabBarPlacement.topBar.minimizesOnScroll)
        #expect(!ActiveTabBarPlacement.sidebar.minimizesOnScroll)
    }
}
