import CoreGraphics
import Testing
@testable import OpenCast

/// A foldable scene keeps the Automatic family it settled on; any other scene
/// follows the window. "Closed" is a compact window and "regular" a regular
/// one; nothing here knows a device.
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

    @Test("Foldable, Closed → regular: the list Automatic settled on in Closed stays")
    func foldableClosedToRegular() {
        var layout = Self.settled(on: .automatic, isRegularWidth: false)
        #expect(layout.layout(for: .automatic, isRegularWidth: false, isFoldableScene: true) == .list)
        // The unfold re-renders with the same preference: observing it again keeps the family.
        layout.observe(.automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: true) == .list)
    }

    @Test("Foldable, regular → Closed: the grid Automatic settled on at regular width stays")
    func foldableRegularToClosed() {
        var layout = Self.settled(on: .automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: true) == .grid)
        layout.observe(.automatic, isRegularWidth: false)
        #expect(layout.layout(for: .automatic, isRegularWidth: false, isFoldableScene: true) == .grid)
    }

    @Test("Foldable, explicit → Automatic: Automatic resolves afresh from the window it is chosen in")
    func foldableExplicitToAutomatic() {
        var layout = Self.settled(on: .automatic, isRegularWidth: true)
        layout.observe(.list, isRegularWidth: false)
        #expect(layout.retainedLayout == nil)
        #expect(layout.layout(for: .list, isRegularWidth: false, isFoldableScene: true) == .list)
        // Chosen again in Closed: a list, though the scene's first Automatic was a grid.
        layout.observe(.automatic, isRegularWidth: false)
        #expect(layout.layout(for: .automatic, isRegularWidth: true, isFoldableScene: true) == .list)

        layout.observe(.grid, isRegularWidth: true)
        layout.observe(.automatic, isRegularWidth: true)
        #expect(layout.layout(for: .automatic, isRegularWidth: false, isFoldableScene: true) == .grid)
    }

    @Test("Foldable, scene recreation: a new scene resolves from its own window", arguments: [true, false])
    func foldableSceneRecreation(isRegularWidth: Bool) {
        let previousScene = Self.settled(on: .automatic, isRegularWidth: !isRegularWidth)
        let recreated = Self.settled(on: .automatic, isRegularWidth: isRegularWidth)
        let expected: LibraryLayout = isRegularWidth ? .grid : .list
        #expect(recreated.layout(for: .automatic, isRegularWidth: isRegularWidth, isFoldableScene: true) == expected)
        #expect(previousScene.layout(for: .automatic, isRegularWidth: isRegularWidth, isFoldableScene: true) != expected)
    }

    @Test("Before its first observation Automatic shows the resolver's answer", arguments: [true, false])
    func unobservedFollowsResolver(isRegularWidth: Bool) {
        let layout = AutomaticLibraryLayout()
        #expect(layout.layout(for: .automatic, isRegularWidth: isRegularWidth, isFoldableScene: true)
            == LibraryLayoutPreference.automatic.resolved(isRegularWidth: isRegularWidth))
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
        // Launched in Closed, then unfolded: the regular window reports the band.
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
