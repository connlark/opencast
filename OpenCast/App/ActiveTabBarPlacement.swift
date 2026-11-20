import SwiftUI

/// `TabBarPlacement` has no rail case, so the rail comes from
/// `toolbarVerticalEdge`, non-nil wherever the system places a vertical bar.
nonisolated enum ActiveTabBarPlacement: Equatable, Sendable {
    case bottomBar
    case rail
    case topBar
    case sidebar

    init?(tabBarPlacement: TabBarPlacement?, toolbarVerticalEdge: HorizontalEdge?) {
        if toolbarVerticalEdge != nil {
            self = .rail
        } else if tabBarPlacement == .bottomBar {
            self = .bottomBar
        } else if tabBarPlacement == .topBar {
            self = .topBar
        } else if tabBarPlacement == .sidebar {
            self = .sidebar
        } else {
            return nil
        }
    }

    var minimizesOnScroll: Bool {
        self == .bottomBar
    }
}
