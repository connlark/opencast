import SwiftUI
import Testing
@testable import OpenCast

/// The widths below are fixtures shaped like lane SHELL's measured capsules
/// (the iPhone Duo's Closed 290, Book 346, Open portrait 400 and Open
/// landscape 775 pt, and S1's pinned-iPhone 360 pt), not constants the code
/// knows.
@Suite("Tab accessory row")
struct TabAccessoryRowTests {
    private static func expanded(width: Double) -> TabAccessoryGeometry {
        .expanded(frame: CGRect(x: 20, y: 600, width: width, height: 56))
    }

    @Test(
        "The row follows the measured width at each threshold",
        arguments: [
            (width: 290.0, row: TabAccessoryRow.dense),
            (width: 319.5, row: .dense),
            (width: 320, row: .standard),
            (width: 346, row: .standard),
            (width: 360, row: .standard),
            (width: 400, row: .standard),
            (width: 619.5, row: .standard),
            (width: 620, row: .wide),
            (width: 775, row: .wide)
        ]
    )
    func thresholds(width: Double, row: TabAccessoryRow) {
        #expect(TabAccessoryRow(expandedWidth: width) == row)
        #expect(TabAccessoryRow(geometry: Self.expanded(width: width), isInline: false) == row)
    }

    @Test("An accessory with no placement yet is treated as expanded")
    func undefinedPlacementIsExpanded() {
        let closed = TabAccessoryGeometry.undefined(frame: CGRect(x: 50, y: 602, width: 290, height: 56))
        let openLandscape = TabAccessoryGeometry.undefined(frame: CGRect(x: 50, y: 593, width: 775, height: 56))
        #expect(TabAccessoryRow(geometry: closed, isInline: false) == .dense)
        #expect(TabAccessoryRow(geometry: openLandscape, isInline: false) == .wide)
    }

    @Test("Before the first report, or with no accessory, the row is standard")
    func defaultBeforeAReport() {
        #expect(TabAccessoryRow(expandedWidth: nil) == .standard)
        #expect(TabAccessoryRow(geometry: .undefined(frame: nil), isInline: false) == .standard)
        #expect(TabAccessoryRow(geometry: .expanded(frame: nil), isInline: false) == .standard)
        #expect(TabAccessoryRow(geometry: .absent, isInline: false) == .standard)
    }

    @Test("The inline accessory keeps today's inline layout at every width", arguments: [200.0, 290, 400, 775])
    func inlineWins(width: Double) {
        let frame = CGRect(x: 60, y: 760, width: width, height: 44)
        #expect(TabAccessoryRow(geometry: .inline(frame: frame), isInline: true) == .standard)
        #expect(TabAccessoryRow(geometry: Self.expanded(width: width), isInline: true) == .standard)
    }

    @Test("A report made while inline does not size the expanded row")
    func inlineReportIsNotAnExpandedWidth() {
        let inlineReport = TabAccessoryGeometry.inline(frame: CGRect(x: 60, y: 760, width: 250, height: 44))
        #expect(TabAccessoryRow.expandedWidth(of: inlineReport) == nil)
        #expect(TabAccessoryRow(geometry: inlineReport, isInline: false) == .standard)
    }

    @Test("Each row's fixed horizontal parts at the default text size")
    func fixedPartSums() {
        // Padding + artwork + gap to the title + a gap and a 44 pt control
        // per control (and one more gap before the wide row's scrubber).
        #expect(TabAccessoryRow.dense.metrics.fixedWidth == Double(8 + 30 + 8 + 2 + 44 + 2 + 44 + 8))
        #expect(TabAccessoryRow.dense.metrics.fixedWidth == 146)
        #expect(TabAccessoryRow.standard.metrics.fixedWidth == Double(12 + 38 + 10 + 8 + 44 + 8 + 44 + 12))
        #expect(TabAccessoryRow.standard.metrics.fixedWidth == 176)
        #expect(TabAccessoryRow.wide.metrics.fixedWidth == Double(12 + 38 + 10 + 4 * 8 + 3 * 44 + 12))
        #expect(TabAccessoryRow.wide.metrics.fixedWidth == 236)
    }

    @MainActor
    @Test("The thresholds follow from the fixed parts, the title floor and the scrubber")
    func thresholdDerivations() {
        let closedCapsule = 290.0
        #expect(TabAccessoryRow.titleFloor == closedCapsule - TabAccessoryRow.dense.metrics.fixedWidth)
        #expect(TabAccessoryRow.denseThreshold == TabAccessoryRow.standard.metrics.fixedWidth + TabAccessoryRow.titleFloor)
        #expect(
            TabAccessoryRow.wideThreshold
                == TabAccessoryRow.wide.metrics.fixedWidth + TabAccessoryRow.titleFloor + TabAccessoryRow.scrubberWidth
        )
        // One point of scrubber travel is one default skip forward through a
        // 60-minute episode.
        #expect(TabAccessoryRow.scrubberWidth == 3600 / PlaybackSkipIntervalOption.defaultForward.seconds)
        // Each row gives its title at least the floor across its own range.
        #expect(TabAccessoryRow.denseThreshold - TabAccessoryRow.standard.metrics.fixedWidth >= TabAccessoryRow.titleFloor)
        #expect(
            TabAccessoryRow.wideThreshold - TabAccessoryRow.wide.metrics.fixedWidth - TabAccessoryRow.scrubberWidth
                >= TabAccessoryRow.titleFloor
        )
    }

    @Test("The dense and wide rows are 44 pt tall; the standard row keeps its 6 pt above and below")
    func rowHeights() {
        #expect(TabAccessoryRow.dense.metrics.verticalPadding == 0)
        #expect(TabAccessoryRow.wide.metrics.verticalPadding == 0)
        #expect(TabAccessoryRow.standard.metrics.verticalPadding == 6)
        #expect(TabAccessoryRow.controlSide == 44)
    }

    /// The measured element: whatever row it holds (stand-ins whose widths
    /// are the rows' fixed parts and more), it takes the proposed width and
    /// answers one constant ideal width, so the row cannot move the
    /// measurement that picked it.
    @MainActor
    @Test("The wrapper's width does not depend on the row inside it", arguments: [146.0, 176, 476, 900])
    func wrapperWidthIndependence(contentWidth: Double) {
        let wrapped = Color.clear
            .frame(width: contentWidth, height: 44)
            .tabAccessoryRowContainer()
        let ideal = UIHostingController(rootView: wrapped.fixedSize())
            .sizeThatFits(in: CGSize(width: 1000, height: 100))
        #expect(Double(ideal.width) == TabAccessoryRow.denseThreshold, "ideal \(ideal.width)")

        for proposed in [290.0, 360, 775] {
            let size = UIHostingController(rootView: wrapped)
                .sizeThatFits(in: CGSize(width: proposed, height: 56))
            #expect(Double(size.width) == proposed, "proposed \(proposed), got \(size.width)")
        }
    }

    /// The dense title is one line at every text size: a long title
    /// truncates in the dense title's floor instead of wrapping.
    @MainActor
    @Test("The dense title never wraps", arguments: [DynamicTypeSize.large, .accessibility3])
    func denseTitleIsOneLine(size: DynamicTypeSize) {
        func height(of title: String) -> CGFloat {
            let view = MiniPlayerMetadataView(
                title: title,
                podcastTitle: "UI Test Show",
                showsSecondaryLine: false
            )
            .environment(\.dynamicTypeSize, size)
            return UIHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: TabAccessoryRow.titleFloor, height: 200))
                .height
        }
        let short = height(of: "Episode")
        let long = height(of: "Deterministic UI Episode With A Title Far Longer Than The Capsule")
        #expect(long == short, "one line \(short), long title \(long)")
    }
}
