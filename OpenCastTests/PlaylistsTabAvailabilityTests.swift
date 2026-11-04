import SwiftUI
import Testing
@testable import OpenCast

/// The poses and transitions below are fixtures from lane A's probe logs on
/// the iPhone Duo simulator (A1: the size class and `toolbarVerticalEdge`
/// per pose; A8: what a fold reads on the way), not cases the code knows.
@Suite("Playlists tab availability")
struct PlaylistsTabAvailabilityTests {
    private typealias Reading = (sizeClass: UserInterfaceSizeClass?, hasRail: Bool)

    @Test(
        "Offered with a rail, at regular width or in a foldable scene; withheld only by a compact bar with no rail",
        arguments: [
            (hasRail: true, sizeClass: UserInterfaceSizeClass?.some(.compact), offered: true),
            (hasRail: true, sizeClass: .regular, offered: true),
            (hasRail: true, sizeClass: nil, offered: true),
            (hasRail: false, sizeClass: .compact, offered: false),
            (hasRail: false, sizeClass: .regular, offered: true),
            (hasRail: false, sizeClass: nil, offered: false)
        ]
    )
    func everyCell(hasRail: Bool, sizeClass: UserInterfaceSizeClass?, offered: Bool) {
        #expect(
            OpenCastTabRootView.offersPlaylistsTab(hasRail: hasRail, horizontalSizeClass: sizeClass, isFoldableScene: false)
                == offered
        )
        #expect(OpenCastTabRootView.offersPlaylistsTab(hasRail: hasRail, horizontalSizeClass: sizeClass, isFoldableScene: true))
    }

    @Test("Every iPhone Duo pose offers the tab")
    func everyDuoPoseOffersTheTab() {
        let poses: [(name: String, sizeClass: UserInterfaceSizeClass, hasRail: Bool)] = [
            ("Closed", .compact, true),
            ("Book", .regular, true),
            ("Open landscape", .regular, true),
            ("Open portrait", .regular, false),
            ("Laptop", .regular, false)
        ]
        for pose in poses {
            #expect(
                OpenCastTabRootView.offersPlaylistsTab(
                    hasRail: pose.hasRail,
                    horizontalSizeClass: pose.sizeClass,
                    isFoldableScene: false
                ),
                "\(pose.name)"
            )
        }
    }

    /// The decision for each reading, with the scene's rail mark latched as
    /// the tab root latches it; `foldReported` stands for the scene's
    /// `.division` mark.
    private static func decisions(for readings: [Reading], foldReported: Bool = false) -> [Bool] {
        var hasShownRail = false
        return readings.map { reading in
            hasShownRail = hasShownRail || reading.hasRail
            return OpenCastTabRootView.offersPlaylistsTab(
                hasRail: reading.hasRail,
                horizontalSizeClass: reading.sizeClass,
                isFoldableScene: hasShownRail || foldReported
            )
        }
    }

    @Test("A fold passes a compact window with no rail and keeps the tab", arguments: [false, true])
    func foldIntermediateKeepsTheTab(foldReported: Bool) {
        // Closed → Open landscape, then back.
        let unfold: [Reading] = [(.compact, true), (.compact, false), (.regular, true)]
        let fold: [Reading] = [(.regular, true), (.compact, false), (.compact, true)]
        #expect(Self.decisions(for: unfold + fold, foldReported: foldReported) == Array(repeating: true, count: 6))
        // Launched in Open portrait (no rail, a fold reported), then folded shut.
        let fromPortrait: [Reading] = [(.regular, false), (.compact, false), (.compact, true)]
        #expect(Self.decisions(for: fromPortrait, foldReported: true) == [true, true, true])
    }

    @Test("An iPhone withholds the tab; an iPad window hands it over when it turns compact")
    func withoutARailOrAFold() {
        #expect(Self.decisions(for: [(.compact, false)]) == [false])
        #expect(Self.decisions(for: [(.regular, false), (.compact, false), (.regular, false)]) == [true, false, true])
    }
}
