import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@Suite("Now Playing card geometry")
struct NowPlayingCardGeometryTests {
    static let closedWindow = CGSize(width: 466, height: 678)
    static let closedInsets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
    /// The camera and the status cluster at the top of the rail column.
    static let closedOcclusions = [
        CGRect(x: 399.7, y: 29.3, width: 37, height: 37),
        CGRect(x: 382, y: 0, width: 84, height: 174),
    ]
    static let iPhoneWindow = CGSize(width: 402, height: 874)
    static let iPhoneInsets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
    /// The inner display landscape-shaped (Book, Open landscape): the 84 pt
    /// trailing rail, its status cluster 84 × 124 at the rail's top.
    static let innerLandscapeWindow = CGSize(width: 951, height: 669)
    static let innerLandscapeInsets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
    static let innerLandscapeCluster = CGRect(x: 867, y: 0, width: 84, height: 124)
    static let bookBand = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    /// The inner display portrait-shaped (Laptop, Open portrait): an 82 pt top
    /// bar, its status cluster 144 × 82 at the bar's trailing corner.
    static let innerPortraitWindow = CGSize(width: 669, height: 951)
    static let innerPortraitInsets = EdgeInsets(top: 82, leading: 0, bottom: 34, trailing: 0)
    static let innerPortraitCluster = CGRect(x: 525, y: 0, width: 144, height: 82)
    static let laptopBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    static func closed(isAccessibilitySize: Bool = false, occlusions: [CGRect] = closedOcclusions) -> NowPlayingCardGeometry {
        NowPlayingCardGeometry(
            windowSize: closedWindow,
            safeAreaInsets: closedInsets,
            isRegular: false,
            isAccessibilitySize: isAccessibilitySize,
            pose: .compact,
            occlusions: occlusions
        )
    }

    static func pinnedIPhone(isAccessibilitySize: Bool = false) -> NowPlayingCardGeometry {
        NowPlayingCardGeometry(
            windowSize: iPhoneWindow,
            safeAreaInsets: iPhoneInsets,
            isRegular: false,
            isAccessibilitySize: isAccessibilitySize,
            pose: .compact,
            occlusions: []
        )
    }

    @Test("Closed: the status cluster covers the top-trailing corner, so More sits top-leading at (20, 62), clear of both regions")
    func closedMoreClearsTheCluster() {
        let geometry = Self.closed()
        let more = CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44))
        #expect(geometry.moreIsLeading)
        #expect(geometry.moreOrigin == CGPoint(x: 20, y: 62))
        for region in Self.closedOcclusions {
            #expect(!NowPlayingCardGeometry.overlaps(more, region))
        }
    }

    @Test("Closed: the toasts start 48 pt below More, inside the safe width, clear of the rail column")
    func closedToastsClearTheRail() {
        let geometry = Self.closed()
        #expect(geometry.toastTop(height: 120) == 110)
        #expect(geometry.toastLeadingPadding == 16)
        #expect(geometry.toastTrailingPadding == CGFloat(84 + 16))
        let toast = CGRect(x: 16, y: geometry.toastTop(height: 120), width: 466 - 16 - 100, height: 120)
        for region in Self.closedOcclusions {
            #expect(!NowPlayingCardGeometry.overlaps(toast, region))
        }
    }

    @Test("A toast moves below an occlusion region its measured height would reach")
    func toastUsesItsMeasuredHeight() {
        let cluster = CGRect(x: 382, y: 0, width: 84, height: 174)
        let lowRegion = CGRect(x: 0, y: 160, width: 300, height: 20)
        let geometry = Self.closed(occlusions: [cluster, lowRegion])
        #expect(geometry.toastTop(height: 44) == 110)
        #expect(geometry.toastTop(height: 70) == 180)
    }

    @Test("Closed: interactive rows start below the status cluster's bottom edge")
    func closedControlsFloor() {
        #expect(Self.closed().controlsMinY == 174)
        #expect(Self.closed(occlusions: []).controlsMinY == 0)
    }

    @Test("Pinned iPhone: More stays top-trailing at (338, 62), the content at 150 and the toasts at 110; the bottom moves inside the safe area")
    func pinnedIPhoneGeometry() {
        let geometry = Self.pinnedIPhone()
        #expect(!geometry.moreIsLeading)
        #expect(geometry.moreOrigin == CGPoint(x: 402 - 20 - 44, y: 62))
        #expect(geometry.contentTopPadding == 150)
        #expect(geometry.artworkBoundTopPadding == 150)
        #expect(geometry.toastTop(height: 60) == 110)
        #expect(geometry.contentBottomPadding == CGFloat(34 + 22))
    }

    @Test("More moves below an occlusion region over the corner it moves to")
    func moreMovesBelowARegionAtItsCorner() {
        let cluster = CGRect(x: 382, y: 0, width: 84, height: 174)
        let leadingRegion = CGRect(x: 0, y: 40, width: 100, height: 60)
        let geometry = Self.closed(occlusions: [cluster, leadingRegion])
        #expect(geometry.moreIsLeading)
        #expect(geometry.moreOrigin == CGPoint(x: 20, y: 100))
    }

    @Test("A regular card with no fold keeps today's size and centred position, More top-trailing; its insets count from the card")
    func regularFlatCard() {
        let window = CGSize(width: 1032, height: 1376)
        let geometry = NowPlayingCardGeometry(
            windowSize: window,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
            isRegular: true,
            isAccessibilitySize: false,
            pose: .regularFlat,
            occlusions: []
        )
        #expect(geometry.cardFrame == CGRect(x: (1032.0 - 660) / 2, y: 1376 - 860, width: 660, height: 860))
        #expect(geometry.contentInsets == EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0))
        #expect(geometry.contentTopPadding == 96)
        #expect(geometry.contentBottomPadding == CGFloat(20 + 32))
        #expect(!geometry.moreIsLeading)
        #expect(geometry.moreOrigin == CGPoint(x: 660 - 20 - 44, y: 18))
        #expect(geometry.toastTop(height: 60) == 66)
        #expect(geometry.horizontalFold == nil)
    }

    @Test("Open landscape (the band inactive, so flat): today's centred 660 pt card, More top-trailing clear of the rail's cluster")
    func openLandscapeNothingMoves() {
        let geometry = NowPlayingCardGeometry(
            windowSize: Self.innerLandscapeWindow,
            safeAreaInsets: Self.innerLandscapeInsets,
            isRegular: true,
            isAccessibilitySize: false,
            pose: WindowPose(
                horizontalSizeClass: .regular,
                divisionRegions: [WindowDivisionRegion(frame: Self.bookBand, isActive: false)]
            ),
            occlusions: [Self.innerLandscapeCluster]
        )
        #expect(geometry.cardFrame == CGRect(x: (951.0 - 660) / 2, y: 669 - 597, width: 660, height: 597))
        #expect(!geometry.moreIsLeading)
        #expect(geometry.horizontalFold == nil)
    }
}
