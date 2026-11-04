/// The path contract of a two-pane root. A section's `AppNavigationPaths`
/// slot is its only navigation state, in both containers:
///
/// - In the split, `path.first` is the detail column's root page and the
///   rest is the detail stack. The sidebar's highlight is derived from
///   `path.first`, never stored.
/// - In the stack, the path is today's `NavigationStack` path over the root
///   content.
///
/// So a switch between the containers keeps the route sequence and the
/// visible page. Writes from the containers' own bindings are applied only
/// while their container is the current one and, for the detail stack, only
/// while the detail root they were made for is still the path's head: an
/// outgoing container or an obsolete detail stack never overwrites a newer
/// path. Writes from outside (deep links, Now Playing's Go to, pruning, a
/// reset) are authoritative and the split derives its columns from them.
enum TwoPaneRootPath {
    /// The split's detail root: the first route, nil for the placeholder.
    static func head(of path: [AppRoute]) -> AppRoute? {
        path.first
    }

    /// The split's detail stack: everything after the head.
    static func suffix(of path: [AppRoute]) -> [AppRoute] {
        Array(path.dropFirst())
    }

    /// A route opened from the root content itself (a sidebar row, tile or
    /// collection entry, one of the root's callbacks or its context menus):
    /// in the split it REPLACES the path, so the page becomes the detail's
    /// root; in the stack it is pushed, as today.
    static func openingFromRoot(
        _ route: AppRoute,
        in path: [AppRoute],
        container: TwoPaneRootContainer
    ) -> [AppRoute] {
        switch container {
        case .split:
            [route]
        case .stack:
            path + [route]
        }
    }

    /// The path after the split's detail stack writes `suffix` (a push or a
    /// pop inside the detail), or nil when the write is obsolete: the split
    /// is no longer the current container, or the head the detail stack was
    /// built for is no longer the path's head. With no head (the
    /// placeholder) the suffix is the whole path.
    static func writingDetailSuffix(
        _ suffix: [AppRoute],
        forHead head: AppRoute?,
        into path: [AppRoute],
        currentContainer: TwoPaneRootContainer
    ) -> [AppRoute]? {
        guard currentContainer == .split, path.first == head else {
            return nil
        }
        guard let head else {
            return suffix
        }
        return [head] + suffix
    }

    /// The path after the stack container writes `newPath`, or nil when the
    /// stack is no longer the current container.
    static func writingStackPath(
        _ newPath: [AppRoute],
        currentContainer: TwoPaneRootContainer
    ) -> [AppRoute]? {
        currentContainer == .stack ? newPath : nil
    }

    /// The split's explicit close of its detail root, for the pages that
    /// close themselves with `dismiss` (an unavailable page's Go Back, the
    /// feed migration's exit): the root route is not a pushed page there, so
    /// `dismiss` cannot remove it. Nil when `route` is no longer the head.
    static func closingRoot(_ route: AppRoute, in path: [AppRoute]) -> [AppRoute]? {
        path.first == route ? [] : nil
    }
}
