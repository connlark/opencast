import Testing
@testable import OpenCast

/// The tab form keys on the scene's fold latch alone: a tab's effective form
/// is always this answer, so every section agrees at every moment.
@MainActor
@Suite("Tab label form")
struct TabLabelFormTests {
    @Test("Icon-only in a scene that has reported a fold, titled otherwise")
    func everyCell() {
        #expect(TabLabelForm.resolve(isFoldableScene: true) == .iconOnly)
        #expect(TabLabelForm.resolve(isFoldableScene: false) == .titled)
    }
}
