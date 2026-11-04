import SwiftUI

/// Where the tab view's section bar is in the current context, read inside
/// the tab view's content (the only place the system reports it) and
/// published by the tab root beside the accessory's geometry.
/// `TabBarPlacement` has no rail case, so the rail comes from
/// `toolbarVerticalEdge`, which is non-nil wherever the system places a
/// vertical bar (the iPhone Duo's outer display) and nil elsewhere.
nonisolated enum ActiveTabBarPlacement: Equatable, Sendable {
    case bottomBar
    case rail
    case topBar
    case sidebar

    /// Nil when the system reports a placement that is none of these.
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

    /// Only a bottom tab bar minimizes on scroll; a rail, a top bar and a
    /// sidebar stay as they are.
    var minimizesOnScroll: Bool {
        self == .bottomBar
    }
}
