/// In the split, `path.first` is the detail root and the rest its stack. A
/// container's own writes apply only while it is current (a detail stack's,
/// only while its head is still the path's); outside writes always apply.
enum TwoPaneRootPath {
    static func head(of path: [AppRoute]) -> AppRoute? {
        path.first
    }

    static func suffix(of path: [AppRoute]) -> [AppRoute] {
        Array(path.dropFirst())
    }

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

    static func writingStackPath(
        _ newPath: [AppRoute],
        currentContainer: TwoPaneRootContainer
    ) -> [AppRoute]? {
        currentContainer == .stack ? newPath : nil
    }

    /// `dismiss` cannot remove the detail root, which is not a pushed page.
    /// nil when `route` is no longer the head.
    static func closingRoot(_ route: AppRoute, in path: [AppRoute]) -> [AppRoute]? {
        path.first == route ? [] : nil
    }
}
