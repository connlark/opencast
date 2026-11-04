import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// The arrangement table, row by row, from the pose model's own inputs. The
/// window sizes and bands are the iPhone Duo's inner display as the simulator
/// reports it (951 × 669 landscape-shaped, 669 × 951 portrait-shaped, the
/// 40 pt `.division` band at 455.5); the square window and the off-centre band
/// are fixtures.
@Suite("Now Playing arrangement")
struct NowPlayingArrangementTests {
    static let wideWindow = CGSize(width: 951, height: 669)
    static let tallWindow = CGSize(width: 669, height: 951)
    static let squareWindow = CGSize(width: 700, height: 700)
    static let compactWindow = CGSize(width: 466, height: 678)
    static let bookBand = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    static let laptopBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    static let flatWideBand = WindowDivisionRegion(frame: bookBand, isActive: false)
    static let flatTallBand = WindowDivisionRegion(frame: laptopBand, isActive: false)

    static func arrangement(
        _ sizeClass: UserInterfaceSizeClass?,
        _ window: CGSize,
        regions: [WindowDivisionRegion] = [],
        isFoldableScene: Bool
    ) -> NowPlayingArrangement {
        NowPlayingArrangement(
            pose: WindowPose(horizontalSizeClass: sizeClass, divisionRegions: regions),
            windowSize: window,
            isFoldableScene: isFoldableScene
        )
    }

    // MARK: The table

    @Test("Compact always wins: every compact or unknown width is today's card, foldable scene or not, banded or not")
    func compactAlwaysWins() {
        let bands = [[], [WindowDivisionRegion(frame: Self.bookBand, isActive: true)], [Self.flatWideBand]]
        for sizeClass in [UserInterfaceSizeClass.compact, nil] {
            for window in [Self.compactWindow, Self.wideWindow, Self.tallWindow] {
                for regions in bands {
                    for isFoldable in [false, true] {
                        #expect(Self.arrangement(sizeClass, window, regions: regions, isFoldableScene: isFoldable) == .card)
                    }
                }
            }
        }
    }

    @Test("Book: a vertical band splits the player and the pane on it, scene flag off or on, any window")
    func bookSplitsOnTheBand() {
        let band = WindowDivisionRegion(frame: Self.bookBand, isActive: true)
        for window in [Self.wideWindow, Self.tallWindow, Self.squareWindow] {
            for isFoldable in [false, true] {
                #expect(
                    Self.arrangement(.regular, window, regions: [band], isFoldableScene: isFoldable)
                        == .split(band: Self.bookBand)
                )
            }
        }
    }

    @Test("Laptop: a horizontal band keeps one card split around it, scene flag off or on, any window")
    func laptopKeepsOneCard() {
        let band = WindowDivisionRegion(frame: Self.laptopBand, isActive: true)
        for window in [Self.tallWindow, Self.wideWindow, Self.squareWindow] {
            for isFoldable in [false, true] {
                #expect(
                    Self.arrangement(.regular, window, regions: [band], isFoldableScene: isFoldable)
                        == .single(band: Self.laptopBand)
                )
            }
        }
    }

    @Test("Flat and foldable: wider than tall splits with no band; taller or square keeps one card")
    func flatFoldableFollowsTheWindowShape() {
        #expect(Self.arrangement(.regular, Self.wideWindow, isFoldableScene: true) == .split(band: nil))
        #expect(Self.arrangement(.regular, Self.tallWindow, isFoldableScene: true) == .single(band: nil))
        #expect(Self.arrangement(.regular, Self.squareWindow, isFoldableScene: true) == .single(band: nil))
        let nearlySquare = CGSize(width: 700.5, height: 700)
        #expect(Self.arrangement(.regular, nearlySquare, isFoldableScene: true) == .split(band: nil))
    }

    @Test("A regular window whose scene never reported a fold keeps today's card at every shape")
    func nonFoldableRegularKeepsTheCard() {
        let iPadWindows = [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032), Self.squareWindow]
        for window in iPadWindows + [Self.wideWindow, Self.tallWindow] {
            #expect(Self.arrangement(.regular, window, isFoldableScene: false) == .card)
        }
    }

    @Test("Inactive and degenerate regions never fold the pose; the flag alone decides flat windows")
    func inactiveRegionsDoNotFold() {
        let degenerate = WindowDivisionRegion(frame: CGRect(x: 455.5, y: 0, width: 0, height: 669), isActive: true)
        #expect(Self.arrangement(.regular, Self.wideWindow, regions: [Self.flatWideBand], isFoldableScene: true) == .split(band: nil))
        #expect(Self.arrangement(.regular, Self.tallWindow, regions: [Self.flatTallBand], isFoldableScene: true) == .single(band: nil))
        #expect(Self.arrangement(.regular, Self.wideWindow, regions: [degenerate], isFoldableScene: false) == .card)
    }

    @Test("Only foldable arrangements take the window-sized surface; the pane style follows the arrangement")
    func surfaceAndPaneStyle() {
        #expect(!NowPlayingArrangement.card.usesWindowSizedSurface)
        #expect(NowPlayingArrangement.split(band: nil).usesWindowSizedSurface)
        #expect(NowPlayingArrangement.split(band: Self.bookBand).usesWindowSizedSurface)
        #expect(NowPlayingArrangement.single(band: nil).usesWindowSizedSurface)
        #expect(NowPlayingArrangement.single(band: Self.laptopBand).usesWindowSizedSurface)
        #expect(NowPlayingArrangement.card.paneStyle == .entryPointsOnly)
        #expect(NowPlayingArrangement.split(band: Self.bookBand).paneStyle == .beside)
        #expect(NowPlayingArrangement.single(band: nil).paneStyle == .disclosure)
        #expect(NowPlayingArrangement.card.band == nil)
        #expect(NowPlayingArrangement.split(band: Self.bookBand).band == Self.bookBand)
        #expect(NowPlayingArrangement.single(band: Self.laptopBand).band == Self.laptopBand)
    }

    // MARK: The scene flag

    @Test("The flag on a layout is the latch or a fold report in this layout's regions, active or inactive")
    func flagOnThisLayout() {
        #expect(!NowPlayingArrangement.isFoldableScene(latched: false, currentRegions: []))
        #expect(NowPlayingArrangement.isFoldableScene(latched: false, currentRegions: [Self.flatWideBand]))
        #expect(NowPlayingArrangement.isFoldableScene(latched: false, currentRegions: [WindowDivisionRegion(frame: Self.bookBand, isActive: true)]))
        #expect(NowPlayingArrangement.isFoldableScene(latched: true, currentRegions: []))
        #expect(!NowPlayingArrangement.isFoldableScene(latched: false, currentRegions: [WindowDivisionRegion(frame: .zero, isActive: false)]))
    }

    /// One layout as the app runs it: the root layer's latch takes the regions
    /// (read with `.includeInactive`), then the overlay resolves the pose from
    /// the same regions and the arrangement from the pose, the window and the
    /// flag.
    @MainActor
    static func layout(
        _ scene: SceneLibraryLayouts,
        _ sizeClass: UserInterfaceSizeClass?,
        _ window: CGSize,
        _ regions: [WindowDivisionRegion],
        latchFirst: Bool = true
    ) -> NowPlayingArrangement {
        if latchFirst {
            scene.markFoldable(ifReported: regions)
        }
        let isFoldable = NowPlayingArrangement.isFoldableScene(latched: scene.isFoldable, currentRegions: regions)
        let arrangement = NowPlayingArrangement(
            pose: WindowPose(horizontalSizeClass: sizeClass, divisionRegions: regions),
            windowSize: window,
            isFoldableScene: isFoldable
        )
        if !latchFirst {
            scene.markFoldable(ifReported: regions)
        }
        return arrangement
    }

    @MainActor
    @Test("Book from launch: empty → inactive → active → empty resolves card, plain split, split on the band, plain split")
    func bookRegionSequence() {
        let scene = SceneLibraryLayouts()
        let active = WindowDivisionRegion(frame: Self.bookBand, isActive: true)
        #expect(Self.layout(scene, .regular, Self.wideWindow, []) == .card)
        #expect(Self.layout(scene, .regular, Self.wideWindow, [Self.flatWideBand]) == .split(band: nil))
        #expect(Self.layout(scene, .regular, Self.wideWindow, [active]) == .split(band: Self.bookBand))
        #expect(Self.layout(scene, .regular, Self.wideWindow, []) == .split(band: nil))
        #expect(scene.isFoldable)
    }

    @MainActor
    @Test("Laptop from launch: empty → inactive → active → empty resolves card, one card, one card on the band, one card")
    func laptopRegionSequence() {
        let scene = SceneLibraryLayouts()
        let active = WindowDivisionRegion(frame: Self.laptopBand, isActive: true)
        #expect(Self.layout(scene, .regular, Self.tallWindow, []) == .card)
        #expect(Self.layout(scene, .regular, Self.tallWindow, [Self.flatTallBand]) == .single(band: nil))
        #expect(Self.layout(scene, .regular, Self.tallWindow, [active]) == .single(band: Self.laptopBand))
        #expect(Self.layout(scene, .regular, Self.tallWindow, []) == .single(band: nil))
    }

    @MainActor
    @Test("The flag is current on the layout that first reports the fold, before the latch has taken it")
    func flagUpdatedBeforeResolution() {
        let scene = SceneLibraryLayouts()
        #expect(Self.layout(scene, .regular, Self.wideWindow, [Self.flatWideBand], latchFirst: false) == .split(band: nil))
        #expect(scene.isFoldable)
    }

    @MainActor
    @Test("A compact window after the scene became foldable is today's card; unfolding again splits")
    func compactAfterFoldable() {
        let scene = SceneLibraryLayouts()
        #expect(Self.layout(scene, .regular, Self.wideWindow, [Self.flatWideBand]) == .split(band: nil))
        #expect(Self.layout(scene, .compact, Self.compactWindow, []) == .card)
        #expect(scene.isFoldable)
        #expect(Self.layout(scene, .regular, Self.wideWindow, []) == .split(band: nil))
    }

    @MainActor
    @Test("A recreated scene starts with no flag: the empty first layout is the card until a region arrives")
    func sceneRecreation() {
        let first = SceneLibraryLayouts()
        #expect(Self.layout(first, .regular, Self.wideWindow, [Self.flatWideBand]) == .split(band: nil))
        let recreated = SceneLibraryLayouts()
        #expect(Self.layout(recreated, .regular, Self.wideWindow, []) == .card)
        #expect(Self.layout(recreated, .regular, Self.wideWindow, [Self.flatWideBand]) == .split(band: nil))
    }

    @MainActor
    @Test("Never cached: a rotation of the flat display re-derives split and single on the next layout")
    func rotationReDerives() {
        let scene = SceneLibraryLayouts()
        #expect(Self.layout(scene, .regular, Self.wideWindow, [Self.flatWideBand]) == .split(band: nil))
        #expect(Self.layout(scene, .regular, Self.tallWindow, [Self.flatTallBand]) == .single(band: nil))
        #expect(Self.layout(scene, .regular, Self.wideWindow, []) == .split(band: nil))
    }
}
