/// In a foldable scene Automatic keeps the family it first resolved to, so folding never flips a
/// grid into a list; other scenes follow the window.
nonisolated struct AutomaticLibraryLayout: Equatable, Sendable {
    private(set) var retainedLayout: LibraryLayout?
    private var lastPreference: LibraryLayoutPreference?

    func layout(
        for preference: LibraryLayoutPreference,
        isRegularWidth: Bool,
        isFoldableScene: Bool
    ) -> LibraryLayout {
        if preference == .automatic, isFoldableScene, let retainedLayout {
            return retainedLayout
        }
        return preference.resolved(isRegularWidth: isRegularWidth)
    }

    mutating func observe(_ preference: LibraryLayoutPreference, isRegularWidth: Bool) {
        defer {
            lastPreference = preference
        }
        guard preference == .automatic else {
            retainedLayout = nil
            return
        }
        if lastPreference != .automatic || retainedLayout == nil {
            retainedLayout = preference.resolved(isRegularWidth: isRegularWidth)
        }
    }
}
