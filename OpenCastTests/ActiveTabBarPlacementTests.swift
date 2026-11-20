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
}
