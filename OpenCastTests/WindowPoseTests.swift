import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@Suite("Window pose decision table")
struct WindowPoseTests {
    private static let verticalBand = CGRect(x: 455, y: 0, width: 40, height: 669)
    private static let horizontalBand = CGRect(x: 0, y: 455, width: 669, height: 40)

    private static func active(_ frame: CGRect) -> WindowDivisionRegion {
        WindowDivisionRegion(frame: frame, isActive: true)
    }

    private static func inactive(_ frame: CGRect) -> WindowDivisionRegion {
        WindowDivisionRegion(frame: frame, isActive: false)
    }

    @Test(
        "A compact or unknown horizontal size class is compact whatever the regions",
        arguments: [UserInterfaceSizeClass.compact, nil]
    )
    func compactWidthIgnoresRegions(horizontalSizeClass: UserInterfaceSizeClass?) {
        let pose = WindowPose(horizontalSizeClass: horizontalSizeClass, divisionRegions: [Self.active(Self.verticalBand)])
        #expect(pose == .compact)
    }

    @Test("Regular width with no region is flat")
    func regularWithoutRegionIsFlat() {
        #expect(WindowPose(horizontalSizeClass: .regular, divisionRegions: []) == .regularFlat)
    }

    @Test("Regular width with a band taller than wide is the vertical fold (Book)")
    func regularWithVerticalBand() {
        let pose = WindowPose(horizontalSizeClass: .regular, divisionRegions: [Self.active(Self.verticalBand)])
        #expect(pose == .foldedVertical(band: Self.verticalBand))
        #expect(pose.band == Self.verticalBand)
    }

    @Test("Regular width with a band wider than tall is the horizontal fold (Laptop)")
    func regularWithHorizontalBand() {
        let pose = WindowPose(horizontalSizeClass: .regular, divisionRegions: [Self.active(Self.horizontalBand)])
        #expect(pose == .foldedHorizontal(band: Self.horizontalBand))
    }

    @Test("An inactive region is ignored")
    func inactiveRegionIsIgnored() {
        let pose = WindowPose(horizontalSizeClass: .regular, divisionRegions: [Self.inactive(Self.verticalBand)])
        #expect(pose == .regularFlat)
    }

    @Test(
        "A region with a zero, negative or non-finite dimension or area is ignored",
        arguments: [
            CGRect(x: 455, y: 0, width: 0, height: 669),
            CGRect(x: 0, y: 455, width: 669, height: 0),
            CGRect(origin: CGPoint(x: 495, y: 0), size: CGSize(width: -40, height: 669)),
            CGRect(origin: CGPoint(x: 0, y: 495), size: CGSize(width: 669, height: -40)),
            CGRect(x: 455, y: 0, width: Double.nan, height: 669),
            CGRect(x: 455, y: 0, width: 40, height: Double.infinity),
            CGRect.null,
            CGRect.infinite,
            CGRect(x: 0, y: 0, width: 1e200, height: 1e200),
        ]
    )
    func degenerateRegionIsIgnored(frame: CGRect) {
        let pose = WindowPose(horizontalSizeClass: .regular, divisionRegions: [Self.active(frame)])
        #expect(pose == .regularFlat)
    }

    @Test("Of several active regions the largest by area wins")
    func largestRegionWins() {
        let small = CGRect(x: 0, y: 200, width: 669, height: 20)
        let pose = WindowPose(
            horizontalSizeClass: .regular,
            divisionRegions: [Self.active(small), Self.active(Self.verticalBand)]
        )
        #expect(pose == .foldedVertical(band: Self.verticalBand))
    }

    @Test("A tie in area keeps the earlier region in the array")
    func tieKeepsArrayOrder() {
        // Both bands are 40 × 669.
        let verticalFirst = WindowPose(
            horizontalSizeClass: .regular,
            divisionRegions: [Self.active(Self.verticalBand), Self.active(Self.horizontalBand)]
        )
        let horizontalFirst = WindowPose(
            horizontalSizeClass: .regular,
            divisionRegions: [Self.active(Self.horizontalBand), Self.active(Self.verticalBand)]
        )
        #expect(verticalFirst == .foldedVertical(band: Self.verticalBand))
        #expect(horizontalFirst == .foldedHorizontal(band: Self.horizontalBand))
    }

    @Test("A larger inactive or degenerate region never beats a usable one")
    func unusableRegionsNeverWin() {
        let wide = CGRect(x: 0, y: 0, width: 900, height: 900)
        let pose = WindowPose(
            horizontalSizeClass: .regular,
            divisionRegions: [
                Self.inactive(wide),
                Self.active(CGRect(x: 0, y: 0, width: 900, height: 0)),
                Self.active(Self.horizontalBand),
            ]
        )
        #expect(pose == .foldedHorizontal(band: Self.horizontalBand))
    }
}
