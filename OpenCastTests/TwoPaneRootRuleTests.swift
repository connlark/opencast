import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// The two-pane roots' container table. The sizes
/// and the band are fixtures from lane A's probe walks on the iPhone Duo
/// simulator (A1: the window per pose; A2: the band at 455.5 × 40), not
/// cases the code knows.
@Suite("Two-pane root container rule")
struct TwoPaneRootRuleTests {
    private static let wide = CGSize(width: 951, height: 669)
    private static let tall = CGSize(width: 669, height: 951)
    private static let square = CGSize(width: 800, height: 800)
    private static let verticalBand = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private static let horizontalBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    private static func container(_ pose: WindowPose, latched: Bool, _ size: CGSize) -> TwoPaneRootContainer {
        TwoPaneRootRule.container(pose: pose, isFoldableScene: latched, windowSize: size)
    }

    @Test("Without the fold latch every pose and window is a stack")
    func unlatchedIsAlwaysAStack() {
        let poses: [WindowPose] = [
            .compact, .regularFlat, .foldedVertical(band: Self.verticalBand), .foldedHorizontal(band: Self.horizontalBand)
        ]
        for pose in poses {
            for size in [Self.wide, Self.tall, Self.square, .zero] {
                #expect(Self.container(pose, latched: false, size) == .stack, "\(pose) \(size)")
            }
        }
    }

    @Test(
        "With the latch: Book splits, a flat window splits only when wider than tall, compact and Laptop stack",
        arguments: [
            (pose: WindowPose.compact, size: TwoPaneRootRuleTests.wide, expected: TwoPaneRootContainer.stack),
            (pose: .compact, size: TwoPaneRootRuleTests.tall, expected: .stack),
            (pose: .compact, size: TwoPaneRootRuleTests.square, expected: .stack),
            (pose: .regularFlat, size: TwoPaneRootRuleTests.wide, expected: .split),
            (pose: .regularFlat, size: TwoPaneRootRuleTests.tall, expected: .stack),
            (pose: .regularFlat, size: TwoPaneRootRuleTests.square, expected: .stack),
            (pose: .foldedVertical(band: TwoPaneRootRuleTests.verticalBand), size: TwoPaneRootRuleTests.wide, expected: .split),
            (pose: .foldedVertical(band: TwoPaneRootRuleTests.verticalBand), size: TwoPaneRootRuleTests.tall, expected: .split),
            (pose: .foldedVertical(band: TwoPaneRootRuleTests.verticalBand), size: TwoPaneRootRuleTests.square, expected: .split),
            (pose: .foldedHorizontal(band: TwoPaneRootRuleTests.horizontalBand), size: TwoPaneRootRuleTests.wide, expected: .stack),
            (pose: .foldedHorizontal(band: TwoPaneRootRuleTests.horizontalBand), size: TwoPaneRootRuleTests.tall, expected: .stack),
            (pose: .foldedHorizontal(band: TwoPaneRootRuleTests.horizontalBand), size: TwoPaneRootRuleTests.square, expected: .stack)
        ]
    )
    func latchedTable(pose: WindowPose, size: CGSize, expected: TwoPaneRootContainer) {
        #expect(Self.container(pose, latched: true, size) == expected)
    }

    @Test("Equal sides use the stack; the smallest excess of width splits")
    func aspectBoundary() {
        #expect(Self.container(.regularFlat, latched: true, CGSize(width: 669, height: 669)) == .stack)
        #expect(Self.container(.regularFlat, latched: true, CGSize(width: 669.5, height: 669)) == .split)
        #expect(Self.container(.regularFlat, latched: true, CGSize(width: 669, height: 669.5)) == .stack)
    }

    /// The five poses as the window-sized reader reads them (A1, A2).
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

    /// A2: the first layout after launch reports no region; the region
    /// arrives on a later layout. Both readings give the same container, so
    /// the first frame does not switch.
    @Test("The first layout without regions picks what the region confirms")
    func initialLayoutWithoutRegions() {
        let bookFirst = TwoPaneRootWindow(horizontalSizeClass: .regular, verticalSizeClass: .regular, size: Self.wide, divisionRegions: [])
        let bookLater = TwoPaneRootWindow(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            size: Self.wide,
            divisionRegions: [WindowDivisionRegion(frame: Self.verticalBand, isActive: true)]
        )
        #expect(bookFirst.pose == .regularFlat)
        #expect(TwoPaneRootRule.container(pose: bookFirst.pose, isFoldableScene: true, windowSize: bookFirst.size) == .split)
        #expect(TwoPaneRootRule.container(pose: bookLater.pose, isFoldableScene: true, windowSize: bookLater.size) == .split)

        let laptopFirst = TwoPaneRootWindow(horizontalSizeClass: .regular, verticalSizeClass: .regular, size: Self.tall, divisionRegions: [])
        let laptopLater = TwoPaneRootWindow(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            size: Self.tall,
            divisionRegions: [WindowDivisionRegion(frame: Self.horizontalBand, isActive: true)]
        )
        #expect(TwoPaneRootRule.container(pose: laptopFirst.pose, isFoldableScene: true, windowSize: laptopFirst.size) == .stack)
        #expect(TwoPaneRootRule.container(pose: laptopLater.pose, isFoldableScene: true, windowSize: laptopLater.size) == .stack)

        // Before the reader's first report.
        let unmeasured = TwoPaneRootWindow.unmeasured
        #expect(TwoPaneRootRule.container(pose: unmeasured.pose, isFoldableScene: true, windowSize: unmeasured.size) == .stack)
        // An inactive band (the flat inner display reports one) is no fold.
        let flatWithInactiveBand = TwoPaneRootWindow(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            size: Self.tall,
            divisionRegions: [WindowDivisionRegion(frame: Self.verticalBand, isActive: false)]
        )
        #expect(flatWithInactiveBand.pose == .regularFlat)
        #expect(flatWithInactiveBand.activeRegions.isEmpty)
    }

    /// Sequences a transition can read on the way (A8: a fold passes a
    /// compact window; a layout can report no region). The modelled
    /// readings change the container at most once: what the Duo really reads
    /// is logged and measured, never assumed.
    @Test("Modelled transitions change the container at most once")
    func modelledTransitionsSwitchOnce() {
        typealias Reading = (pose: WindowPose, size: CGSize, latched: Bool)
        let book: Reading = (.foldedVertical(band: Self.verticalBand), Self.wide, true)
        let laptop: Reading = (.foldedHorizontal(band: Self.horizontalBand), Self.tall, true)
        let sequences: [(name: String, readings: [Reading])] = [
            ("Book -> Laptop", [book, (.regularFlat, Self.wide, true), (.regularFlat, Self.tall, true), laptop]),
            ("Laptop -> Book", [laptop, (.regularFlat, Self.tall, true), (.regularFlat, Self.wide, true), book]),
            ("Open landscape -> Open portrait", [(.regularFlat, Self.wide, true), (.regularFlat, Self.tall, true)]),
            ("Closed -> Book, latch late", [
                (.compact, CGSize(width: 466, height: 678), false), (.compact, Self.wide, false),
                (.regularFlat, Self.wide, false), (.regularFlat, Self.wide, true), book
            ]),
            ("Book -> Closed", [book, (.compact, Self.wide, true), (.compact, CGSize(width: 466, height: 678), true)])
        ]
        for sequence in sequences {
            let containers = sequence.readings.map {
                TwoPaneRootRule.container(pose: $0.pose, isFoldableScene: $0.latched, windowSize: $0.size)
            }
            let changes = zip(containers, containers.dropFirst()).filter { $0 != $1 }.count
            #expect(changes <= 1, "\(sequence.name): \(containers)")
        }
    }

    @Test("The reader's value changes with either size class, so the trace records both")
    func sizeClassesAreInputs() {
        let size = CGSize(width: 466, height: 678)
        let unknown = TwoPaneRootWindow(horizontalSizeClass: nil, verticalSizeClass: .regular, size: size, divisionRegions: [])
        let compact = TwoPaneRootWindow(horizontalSizeClass: .compact, verticalSizeClass: .regular, size: size, divisionRegions: [])
        // Both are the compact pose; the reading still differs.
        #expect(unknown.pose == compact.pose)
        #expect(unknown != compact)
        let compactVertical = TwoPaneRootWindow(horizontalSizeClass: .compact, verticalSizeClass: .compact, size: size, divisionRegions: [])
        #expect(compact != compactVertical)
    }

    @Test("A window that never reports a fold (the iPad, an iPhone) never splits")
    func neverFoldedWindows() {
        for size in [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032), CGSize(width: 402, height: 874)] {
            for sizeClass in [UserInterfaceSizeClass.regular, .compact] {
                let window = TwoPaneRootWindow(horizontalSizeClass: sizeClass, verticalSizeClass: .regular, size: size, divisionRegions: [])
                #expect(TwoPaneRootRule.container(pose: window.pose, isFoldableScene: false, windowSize: window.size) == .stack)
            }
        }
    }
}
