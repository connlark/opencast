/// Keyed on the scene's fold latch, not the pose, so a latched scene keeps its
/// form through every fold and rotation; the rail never shows titles anyway.
nonisolated enum TabLabelForm: String, Equatable {
    case titled
    case iconOnly
}
