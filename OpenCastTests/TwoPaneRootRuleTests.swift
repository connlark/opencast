import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@Suite("Two-pane root container rule")
struct TwoPaneRootRuleTests {
    private static let wide = CGSize(width: 951, height: 669)
    private static let tall = CGSize(width: 669, height: 951)
    private static let verticalBand = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private static let horizontalBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    @Test("The iPhone Duo's five poses, read as the reader reads them")
    func duoPoses() {
        let poses: [(name: String, sizeClass: UserInterfaceSizeClass, size: CGSize, regions: [WindowDivisionRegion], expected: TwoPaneRootContainer)] = [
            ("Closed", .compact, CGSize(width: 466, height: 678), [], .stack),
            ("Book", .regular, Self.wide, [WindowDivisionRegion(frame: Self.verticalBand, isActive: true)], .split),
            ("Open landscape", .regular, Self.wide, [], .split),
            ("Open portrait", .regular, Self.tall, [], .stack),
            ("Laptop", .regular, Self.tall, [WindowDivisionRegion(frame: Self.horizontalBand, isActive: true)], .stack)
        ]
        for pose in poses {
            let window = TwoPaneRootWindow(
                horizontalSizeClass: pose.sizeClass,
                verticalSizeClass: .regular,
                size: pose.size,
                divisionRegions: pose.regions
            )
            #expect(
                TwoPaneRootRule.container(pose: window.pose, isFoldableScene: true, windowSize: window.size)
                    == pose.expected,
                "\(pose.name)"
            )
        }
    }

    @Test("A window that never reports a fold (the iPad, an iPhone) never splits")
    func neverFoldedWindows() {
        let window = TwoPaneRootWindow(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            size: CGSize(width: 1376, height: 1032),
            divisionRegions: []
        )
        #expect(TwoPaneRootRule.container(pose: window.pose, isFoldableScene: false, windowSize: window.size) == .stack)
    }
}
