/// How the tab root declares its tabs' titles. Keyed on the scene's fold
/// latch, not the pose: the rail never shows titles, so the icon-only form
/// changes nothing visible there, and a latched scene keeps the form through
/// every fold and rotation.
nonisolated enum TabLabelForm: String, Equatable {
    case titled
    case iconOnly

    /// Icon-only in a scene that has reported a fold: seven titled tabs do
    /// not fit the iPhone Duo's bottom bar. Every other scene keeps its
    /// titles.
    static func resolve(isFoldableScene: Bool) -> TabLabelForm {
        isFoldableScene ? .iconOnly : .titled
    }
}
