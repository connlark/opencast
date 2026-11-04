import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// Window facts are OBSERVED on the iPhone Duo simulator: the outer display
/// (466 × 678, its safe area and its two occlusion regions) and the inner
/// display (951 × 669 landscape-shaped, 669 × 951 portrait-shaped, the 40 pt
/// `.division` band at 455.5 and the open poses' insets and occlusion regions).
/// The iPhone 18 Pro's insets are its portrait safe area. Other bands are
/// fixtures.
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

    @Test("Closed: the compact card is the window and its content keeps the full width inside the safe vertical extent")
    func closedCardAndContent() {
        let geometry = Self.closed()
        #expect(geometry.cardFrame == CGRect(origin: .zero, size: Self.closedWindow))
        #expect(geometry.contentInsets == EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0))
        #expect(geometry.contentTopPadding == 92)
        #expect(geometry.artworkBoundTopPadding == 92)
        #expect(geometry.contentBottomPadding == CGFloat(34 + 22))
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

    @Test("Closed at accessibility sizes keeps today's 14 pt short-window clearance")
    func closedAccessibilityClearance() {
        #expect(Self.closed(isAccessibilitySize: true).contentTopPadding == 14)
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

    @Test("Pinned iPhone at accessibility sizes: the content starts 28 pt below the safe top, no longer under the Dynamic Island")
    func pinnedIPhoneAccessibilityStartsBelowSafeTop() {
        let geometry = Self.pinnedIPhone(isAccessibilitySize: true)
        #expect(geometry.contentTopPadding == CGFloat(62 + 28))
        #expect(geometry.artworkBoundTopPadding == 28)
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

    @Test("Book confines the card to the band's leading side; More stays top-trailing in it")
    func bookConfinesTheCardToTheLeadingSide() {
        let geometry = NowPlayingCardGeometry(
            windowSize: Self.innerLandscapeWindow,
            safeAreaInsets: Self.innerLandscapeInsets,
            isRegular: true,
            isAccessibilitySize: false,
            pose: WindowPose(
                horizontalSizeClass: .regular,
                divisionRegions: [WindowDivisionRegion(frame: Self.bookBand, isActive: true)]
            ),
            occlusions: [Self.innerLandscapeCluster]
        )
        #expect(geometry.cardFrame.width == 455.5 - 80)
        #expect(geometry.cardFrame.minX == 40)
        #expect(geometry.cardFrame.maxX <= Self.bookBand.minX)
        #expect(!NowPlayingCardGeometry.overlaps(geometry.cardFrame, Self.bookBand))
        #expect(geometry.contentInsets == EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0))
        #expect(!geometry.moreIsLeading)
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

    @Test("Laptop's reported band reaches the card in card-local y; the top bar's cluster stays above the card")
    func laptopBandIsCardLocal() {
        let geometry = NowPlayingCardGeometry(
            windowSize: Self.innerPortraitWindow,
            safeAreaInsets: Self.innerPortraitInsets,
            isRegular: true,
            isAccessibilitySize: false,
            pose: WindowPose(
                horizontalSizeClass: .regular,
                divisionRegions: [WindowDivisionRegion(frame: Self.laptopBand, isActive: true)]
            ),
            occlusions: [Self.innerPortraitCluster]
        )
        #expect(geometry.cardFrame.minY == CGFloat(951 - 860))
        #expect(geometry.contentInsets == EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0))
        #expect(geometry.occlusions.isEmpty)
        #expect(!geometry.moreIsLeading)
        #expect(geometry.horizontalFold == (455.5 - 91)...(495.5 - 91))
    }
}
