import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@Suite("Now Playing arrangement")
struct NowPlayingArrangementTests {
    static let wideWindow = CGSize(width: 951, height: 669)
    static let tallWindow = CGSize(width: 669, height: 951)
    static let squareWindow = CGSize(width: 700, height: 700)

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

    @Test("Flat and foldable: wider than tall splits with no band; taller or square keeps one card")
    func flatFoldableFollowsTheWindowShape() {
        #expect(Self.arrangement(.regular, Self.wideWindow, isFoldableScene: true) == .split(band: nil))
        #expect(Self.arrangement(.regular, Self.tallWindow, isFoldableScene: true) == .single(band: nil))
        #expect(Self.arrangement(.regular, Self.squareWindow, isFoldableScene: true) == .single(band: nil))
        let nearlySquare = CGSize(width: 700.5, height: 700)
        #expect(Self.arrangement(.regular, nearlySquare, isFoldableScene: true) == .split(band: nil))
    }

    @Test(
        "A regular window whose scene never reported a fold keeps today's card at every shape",
        arguments: [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)]
    )
    func nonFoldableRegularKeepsTheCard(window: CGSize) {
        #expect(Self.arrangement(.regular, window, isFoldableScene: false) == .card)
    }
}
