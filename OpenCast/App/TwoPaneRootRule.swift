import SwiftUI

/// The navigation container a two-pane root uses (Library, Inbox, Up Next).
nonisolated enum TwoPaneRootContainer: String, Equatable, Sendable {
    /// `NavigationSplitView`: the root content beside its selected page.
    case split
    /// Today's `NavigationStack`: the root content with pages pushed over it.
    case stack
}

/// Which container the two-pane roots use, from the window as one
/// window-sized reader reports it (its pose and its size, read together)
/// and the scene's division-derived fold latch (`SceneLibraryLayouts`).
///
/// | Fold latch | Pose | Window | Container |
/// | --- | --- | --- | --- |
/// | not set (or no latch object) | any | any | stack |
/// | set | `foldedVertical` (Book) | any | split |
/// | set | `regularFlat` | wider than tall | split |
/// | set | `regularFlat` | as tall as wide or taller | stack |
/// | set | `compact`, `foldedHorizontal` (Laptop) | any | stack |
///
/// A window that has never reported a `.division` region (every iPad window,
/// every other iPhone) never splits: the latch is the only scene input, and
/// a rail is not one.
nonisolated enum TwoPaneRootRule {
    static func container(pose: WindowPose, isFoldableScene: Bool, windowSize: CGSize) -> TwoPaneRootContainer {
        guard isFoldableScene else {
            return .stack
        }
        switch pose {
        case .foldedVertical:
            return .split
        case .regularFlat:
            return windowSize.width > windowSize.height ? .split : .stack
        case .compact, .foldedHorizontal:
            return .stack
        }
    }
}
