import CoreGraphics
import Testing
@testable import OpenCast

@Suite("Automatic Library layout per scene")
struct AutomaticLibraryLayoutTests {
    private static func settled(
        on preference: LibraryLayoutPreference,
        isRegularWidth: Bool
    ) -> AutomaticLibraryLayout {
        var layout = AutomaticLibraryLayout()
        layout.observe(preference, isRegularWidth: isRegularWidth)
        return layout
    }

    // MARK: Foldable scenes

    @Test("Foldable, explicit → Automatic: Automatic resolves afresh from the window it is chosen in")
    func foldableExplicitToAutomatic() {
        var layout = Self.settled(on: .automatic, isRegularWidth: true)
        layout.observe(.list, isRegularWidth: false)
        #expect(layout.retainedLayout == nil)
        #expect(layout.layout(for: .list, isRegularWidth: false, isFoldableScene: true) == .list)
        layout.observe(.automatic, isRegularWidth: false)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: true) == .list)

        layout.observe(.grid, isRegularWidth: true)
        layout.observe(.automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: false, isFoldableScene: true) == .grid)
    }

    @Test("An explicit List or Grid always wins", arguments: [true, false], [true, false])
    func explicitAlwaysWins(isRegularWidth: Bool, isFoldableScene: Bool) {
        let layout = Self.settled(on: .automatic, isRegularWidth: !isRegularWidth)
        #expect(layout.layout(for: .list, isRegularWidth: isRegularWidth, isFoldableScene: isFoldableScene) == .list)
        #expect(layout.layout(for: .grid, isRegularWidth: isRegularWidth, isFoldableScene: isFoldableScene) == .grid)
    }

    // MARK: Scenes that never reported a fold

    @Test("Not foldable: narrow ↔ wide follows the window")
    func nonFoldableFollowsWindow() {
        var layout = Self.settled(on: .automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: false) == .grid)
        layout.observe(.automatic, isRegularWidth: false)
        #expect(layout.layout(for: .automatic, isRegularWidth: false, isFoldableScene: false) == .list)
        layout.observe(.automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: false) == .grid)
    }

    @Test("A scene that becomes foldable keeps the family Automatic first settled on")
    func becomingFoldableKeepsSettledFamily() {
        var layout = Self.settled(on: .automatic, isRegularWidth: false)
        layout.observe(.automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: false) == .grid)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: true) == .list)
    }

    // MARK: The foldable mark

    @Test("Any division region with a positive, finite size marks a fold, active or not")
    func reportsFold() {
        let band = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        #expect(SceneLibraryLayouts.reportsFold([WindowDivisionRegion(frame: band, isActive: true)]))
        #expect(SceneLibraryLayouts.reportsFold([WindowDivisionRegion(frame: band, isActive: false)]))
        #expect(!SceneLibraryLayouts.reportsFold([]))
        #expect(!SceneLibraryLayouts.reportsFold([WindowDivisionRegion(frame: .zero, isActive: true)]))
        #expect(!SceneLibraryLayouts.reportsFold([WindowDivisionRegion(frame: .infinite, isActive: false)]))
    }

    @MainActor
    @Test("A scene is marked foldable once and stays so; its surfaces settle independently")
    func sceneMemory() {
        let scene = SceneLibraryLayouts()
        let band = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        scene.observe(.automatic, on: .library, isRegularWidth: false)
        scene.observe(.automatic, on: .inboxGroups, isRegularWidth: true)
        #expect(!scene.isFoldable)
        #expect(scene.layout(of: .library, for: .automatic, isRegularWidth: true) == .grid)

        scene.markFoldable(ifReported: [WindowDivisionRegion(frame: band, isActive: false)])
        #expect(scene.isFoldable)
        scene.markFoldable(ifReported: [])
        #expect(scene.isFoldable)
        #expect(scene.layout(of: .library, for: .automatic, isRegularWidth: true) == .list)
        #expect(scene.layout(of: .inboxGroups, for: .automatic, isRegularWidth: false) == .grid)
    }
}
