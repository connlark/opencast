/// One surface's Automatic layout in one scene: the Library, or the Inbox
/// grouped by podcast. Automatic resolves through
/// `LibraryLayoutPreference.resolved(isRegularWidth:)` (a grid at regular
/// width, a list otherwise) when the surface first shows it in the scene or
/// when the preference returns to Automatic, and that family is retained.
/// A foldable scene (`SceneLibraryLayouts.isFoldable`) shows the retained
/// family across size-class changes, so folding or unfolding never flips a
/// grid into a list; any other scene keeps following the window. An
/// explicit List or Grid always wins.
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

    /// Records the preference the surface shows: Automatic resolves afresh
    /// only when it is first seen in this scene or chosen again, and is kept
    /// otherwise; an explicit choice drops the retained family.
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
