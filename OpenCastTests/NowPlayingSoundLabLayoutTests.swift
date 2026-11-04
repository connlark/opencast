import SwiftUI
import Testing
@testable import OpenCast

/// The panel widths below are fixtures: the artwork sides the pre-pass-01
/// metrics gave a 466×678 window (Closed, 226 pt), a 951×669 one (Book,
/// 216 pt), a 669×951 one (Laptop, 337 pt) and the iPhone 18 Pro (281 pt).
/// The shipping rule knows none of them; it reads the panel's row space.
@Suite("Sound Lab row fit")
struct NowPlayingSoundLabLayoutTests {
    @Test("The threshold is the toggle row's fixed parts plus its default-size title")
    func thresholdComposition() {
        let parts: [CGFloat] = [
            NowPlayingSoundLabLayout.controlHorizontalPadding,
            NowPlayingSoundLabLayout.nativeGlassButtonLeadingInset,
            NowPlayingSoundLabLayout.controlIconDiameter,
            NowPlayingSoundLabLayout.controlSpacing,
            NowPlayingSoundLabLayout.toggleTitleGap,
            NowPlayingSoundLabLayout.systemSwitchWidth,
            NowPlayingSoundLabLayout.controlHorizontalPadding
        ]
        #expect(NowPlayingSoundLabLayout.labeledToggleFixedWidth == parts.reduce(0, +))
        #expect(NowPlayingSoundLabLayout.iconOnlyRowAreaWidth
            == NowPlayingSoundLabLayout.labeledToggleFixedWidth + NowPlayingSoundLabLayout.voiceBoostTitleWidth)
    }

    /// The labeled Voice Boost row, laid out by SwiftUI at the default text
    /// size, must fit the threshold it defines, and the derivation's measured
    /// inputs must still hold on this runtime.
    @MainActor
    @Test("The labeled toggle row fits the threshold at the default text size")
    func labeledToggleRowFitsThreshold() {
        let row = NowPlayingSoundLabToggle(
            title: "Voice Boost",
            systemImage: "waveform",
            tint: .cyan,
            isEnabled: true,
            isIconOnly: false,
            rowHeight: NowPlayingSoundLabLayout.controlRowHeight,
            isOn: .constant(true)
        )
        .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: row)
        let ideal = host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: NowPlayingSoundLabLayout.controlRowHeight))
        let switchWidth = UISwitch().intrinsicContentSize.width
        let titleWidth = ("Voice Boost" as NSString).size(withAttributes: [
            .font: UIFont.preferredFont(
                forTextStyle: .subheadline,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            )
        ]).width

        #expect(ideal.width > NowPlayingSoundLabLayout.iconOnlyRowAreaWidth - 2, "row \(ideal.width)")
        #expect(ideal.width <= NowPlayingSoundLabLayout.iconOnlyRowAreaWidth, "row \(ideal.width)")
        #expect(switchWidth <= NowPlayingSoundLabLayout.systemSwitchWidth, "switch \(switchWidth)")
        #expect(titleWidth <= NowPlayingSoundLabLayout.voiceBoostTitleWidth, "title \(titleWidth)")
    }

    /// The idle action rows' titles also fit whole at the threshold.
    @MainActor
    @Test("Idle action rows fit the threshold at the default text size", arguments: ["Skip Promos & Ads", "Show Transcript"])
    func idleActionRowsFitThreshold(title: String) {
        let row = NowPlayingSoundLabActionRow(
            title: title,
            systemImage: "megaphone",
            tint: .red,
            phase: .idle,
            isEnabled: true,
            isIconOnly: false,
            rowHeight: NowPlayingSoundLabLayout.controlRowHeight,
            accessibilityValueText: "",
            accessibilityID: title,
            action: {}
        )
        .environment(\.dynamicTypeSize, .large)
        let ideal = UIHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: CGFloat.infinity, height: NowPlayingSoundLabLayout.controlRowHeight))
        #expect(ideal.width <= NowPlayingSoundLabLayout.iconOnlyRowAreaWidth, "\(title) row \(ideal.width)")
    }

    @Test("Titles stay from the threshold up and collapse below it or at accessibility sizes")
    func collapseRule() {
        let threshold = NowPlayingSoundLabLayout.iconOnlyRowAreaWidth
        #expect(!NowPlayingSoundLabLayout.collapsesToIconOnly(rowAreaWidth: threshold, isAccessibilitySize: false))
        #expect(NowPlayingSoundLabLayout.collapsesToIconOnly(rowAreaWidth: threshold - 0.5, isAccessibilitySize: false))
        #expect(NowPlayingSoundLabLayout.collapsesToIconOnly(rowAreaWidth: threshold + 200, isAccessibilitySize: true))
    }

    @Test(
        "The rule reads the panel's row space",
        arguments: [
            (panelWidth: 226.0, collapses: true),
            (panelWidth: 216.0, collapses: true),
            (panelWidth: 281.0, collapses: false),
            (panelWidth: 337.0, collapses: false)
        ]
    )
    func panelFixtures(panelWidth: Double, collapses: Bool) {
        let layout = NowPlayingSoundLabLayout(panelWidth: panelWidth)
        #expect(
            NowPlayingSoundLabLayout.collapsesToIconOnly(rowAreaWidth: layout.rowAreaWidth, isAccessibilitySize: false)
                == collapses,
            "panel \(panelWidth) row \(layout.rowAreaWidth)"
        )
    }

    @Test("Row space grows with the panel, so one width separates the two states")
    func rowSpaceIsMonotonic() {
        var previous: CGFloat = -1
        var crossings = 0
        var previousCollapses = true
        for panelWidth in stride(from: 0.0, through: 700, by: 1) {
            let layout = NowPlayingSoundLabLayout(panelWidth: panelWidth)
            #expect(layout.rowAreaWidth >= previous, "panel \(panelWidth)")
            previous = layout.rowAreaWidth
            let collapses = NowPlayingSoundLabLayout.collapsesToIconOnly(
                rowAreaWidth: layout.rowAreaWidth,
                isAccessibilitySize: false
            )
            if collapses != previousCollapses {
                crossings += 1
            }
            previousCollapses = collapses
        }
        #expect(crossings == 1)
    }

    // MARK: The inline floor and the narrow rail

    /// Today's rules before the inline floor, the oracle from 220 pt up.
    static func todaysRail(_ panelWidth: CGFloat) -> CGFloat {
        min(54, max(40, panelWidth * 0.18))
    }

    static func todaysInset(_ panelWidth: CGFloat) -> CGFloat {
        max(9, panelWidth * 0.035)
    }

    static func todaysRows(
        panelHeight: CGFloat,
        inset: CGFloat,
        rowCount: Int,
        isAccessibilitySize: Bool
    ) -> NowPlayingSoundLabLayout.RowMetrics {
        let constrained = isAccessibilitySize || panelHeight < 250
        guard constrained else {
            return .init(rowHeight: 56, rowSpacing: panelHeight > 290 ? 7 : 5, showsHeader: true)
        }
        let room = panelHeight - 2 * inset - CGFloat(rowCount) * 44
        return .init(
            rowHeight: 44,
            rowSpacing: rowCount > 1 ? min(14, max(2, room / CGFloat(rowCount - 1))) : 14,
            showsHeader: false
        )
    }

    @Test("The inline floor is the larger of the toggle-width and the three-row height budgets, from the constants")
    func inlineFloorComposition() {
        typealias Layout = NowPlayingSoundLabLayout
        #expect(Layout.minimumRailStrip == Layout.minimumContentInset + Layout.railCapsuleWidth)
        let toggleBudget = Layout.labeledToggleFixedWidth + Layout.minimumContentInset + Layout.artworkGutter
            + Layout.minimumRailStrip
        let heightBudget = CGFloat(Layout.maximumRowCount) * Layout.compactRowHeight
            + CGFloat(Layout.maximumRowCount - 1) * Layout.minimumRowSpacing
            + 2 * Layout.minimumContentInset
        #expect(Layout.inlineFloor == max(toggleBudget, heightBudget))
        // With today's constants: 120 + 9 + 4 + 12 and 3 × 44 + 2 × 2 + 2 × 9.
        #expect(Layout.minimumRailStrip == 12.0)
        #expect(toggleBudget == 145.0)
        #expect(heightBudget == 154.0)
        #expect(Layout.inlineFloor == 154.0)
    }

    @Test("The rail never shrinks as the panel grows, gives the rows their 120 pt first, and is today's from 173 pt")
    func railRuleIsMonotonicAndHandsBackAt173() {
        typealias Layout = NowPlayingSoundLabLayout
        var previousRail: CGFloat = 0
        for panelWidth in stride(from: 0.0, through: 700, by: 0.25) {
            let layout = Layout(panelWidth: panelWidth)
            #expect(layout.artworkRailWidth >= previousRail, "panel \(panelWidth)")
            previousRail = layout.artworkRailWidth
            #expect(layout.contentInset == Self.todaysInset(panelWidth), "panel \(panelWidth)")
            #expect(layout.artworkRailWidth >= Layout.minimumRailStrip, "panel \(panelWidth)")
            #expect(layout.artworkRailWidth <= Self.todaysRail(panelWidth), "panel \(panelWidth)")
            if panelWidth >= 173 {
                #expect(layout.artworkRailWidth == Self.todaysRail(panelWidth), "panel \(panelWidth)")
            } else if panelWidth >= Layout.inlineFloor {
                #expect(layout.artworkRailWidth < Self.todaysRail(panelWidth), "panel \(panelWidth)")
            }
            if panelWidth >= 145 {
                #expect(
                    layout.rowAreaWidth >= Layout.labeledToggleFixedWidth - 0.000_1,
                    "panel \(panelWidth) row \(layout.rowAreaWidth)"
                )
            }
        }
        // The hand-over: 173 − 9 − 4 − 120 = 40, today's rail there.
        let handOver = Layout(panelWidth: 173)
        #expect(handOver.artworkRailWidth == 40.0)
        #expect(handOver.rowAreaWidth == 120.0)
        #expect(Layout(panelWidth: 172.5).artworkRailWidth < 40)
    }

    @Test("Below 220 pt the exposed artwork stays inside the rail; from 220 pt it is today's 18 %")
    func exposedArtworkStaysInTheRail() {
        typealias Layout = NowPlayingSoundLabLayout
        for panelWidth in stride(from: Layout.inlineFloor, through: 700, by: 0.25) {
            let layout = Layout(panelWidth: panelWidth)
            if panelWidth < 220 {
                #expect(
                    layout.artworkExposedWidth <= layout.artworkRailWidth + 0.000_1,
                    "panel \(panelWidth) exposed \(layout.artworkExposedWidth) rail \(layout.artworkRailWidth)"
                )
            } else {
                #expect(layout.artworkExposedWidth == panelWidth * Layout.artworkVisibleFraction, "panel \(panelWidth)")
            }
            #expect(layout.protectedLeadingSpace == layout.artworkRailWidth + layout.artworkGutter)
        }
    }

    @Test("The capsule count follows the whole panel height, up to twelve, and the column never outgrows the panel")
    func capsuleCountPerHeight() {
        typealias Layout = NowPlayingSoundLabLayout
        let column = { (count: Int) in
            CGFloat(count) * Layout.railCapsuleHeight + CGFloat(max(0, count - 1)) * Layout.railCapsuleSpacing
        }
        for panelHeight in stride(from: 0.0, through: 700, by: 0.25) {
            let count = Layout.railCapsuleCount(panelHeight: panelHeight)
            #expect((0...Layout.maximumRailCapsuleCount).contains(count))
            #expect(column(count) <= panelHeight + 0.000_1, "height \(panelHeight) count \(count)")
            if count < Layout.maximumRailCapsuleCount {
                #expect(column(count + 1) > panelHeight, "height \(panelHeight) count \(count)")
            }
        }
        // Twelve capsules are today's 220 pt column: 12 × 11 + 11 × 8.
        #expect(column(Layout.maximumRailCapsuleCount) == 220.0)
        #expect(Layout.railCapsuleCount(panelHeight: 219.99) == 11)
        #expect(Layout.railCapsuleCount(panelHeight: 220) == 12)
    }

    /// The fixtures: the non-accessibility fit's 64 pt floor, the inline
    /// floor, Closed at L (`NowPlayingContentMetricsTests.closedFitsAtLarge`),
    /// Closed at AX XXL (`accessibilityXXLScrolls`), the pinned iPhone at
    /// AX XXXL (`pinnedIPhoneAccessibilityBoundUnchanged`).
    @Test(
        "The fixtures below 220 pt: the floor, the rail, the capsules and the gaps",
        arguments: [
            (side: 64.0, inline: false, rail: 12.0, capsules: 3, ax: false),
            (side: 154.0, inline: true, rail: 21.0, capsules: 8, ax: false),
            (side: 156.33, inline: true, rail: 23.33, capsules: 8, ax: false),
            (side: 166.92, inline: true, rail: 33.92, capsules: 9, ax: true),
            (side: 214.24, inline: true, rail: 40.0, capsules: 11, ax: true)
        ]
    )
    func narrowFixtures(side: Double, inline: Bool, rail: Double, capsules: Int, ax: Bool) {
        typealias Layout = NowPlayingSoundLabLayout
        let side = CGFloat(side)
        let layout = Layout(panelWidth: side)
        #expect(Layout.showsInline(panelSide: side) == inline)
        #expect(abs(layout.artworkRailWidth - rail) < 0.001, "rail \(layout.artworkRailWidth)")
        #expect(Layout.railCapsuleCount(panelHeight: side) == capsules)
        guard inline else {
            return
        }
        #expect(layout.contentInset == 9.0)
        #expect(layout.rowAreaWidth >= Layout.labeledToggleFixedWidth - 0.001, "row \(layout.rowAreaWidth)")
        #expect(layout.artworkExposedWidth <= layout.artworkRailWidth + 0.001)
        let rows = Layout.rowMetrics(panelHeight: side, verticalInset: layout.contentInset, rowCount: 3, isAccessibilitySize: ax)
        #expect(rows.rowHeight == Layout.compactRowHeight)
        #expect(!rows.showsHeader)
        #expect(rows.rowSpacing >= Layout.minimumRowSpacing)
        let column = 2 * layout.contentInset + 3 * rows.rowHeight + 2 * rows.rowSpacing
        #expect(column <= side + 0.001, "column \(column)")
        #expect(Layout.collapsesToIconOnly(rowAreaWidth: layout.rowAreaWidth, isAccessibilitySize: ax))
    }

    @Test("At the floor the three rows close to their 2 pt gaps and fill the square exactly")
    func floorBoundary() {
        typealias Layout = NowPlayingSoundLabLayout
        #expect(Layout.showsInline(panelSide: Layout.inlineFloor))
        #expect(!Layout.showsInline(panelSide: Layout.inlineFloor - 0.01))
        let layout = Layout(panelWidth: Layout.inlineFloor)
        let rows = Layout.rowMetrics(panelHeight: Layout.inlineFloor, verticalInset: layout.contentInset, rowCount: 3, isAccessibilitySize: false)
        #expect(rows.rowSpacing == Layout.minimumRowSpacing)
        #expect(layout.rowAreaWidth == Layout.labeledToggleFixedWidth)
    }

    /// 220 pt is where the twelve capsules fit; 280.8 pt is the pinned
    /// iPhone's L artwork (`pinnedIPhoneKeepsTodaysStack`); either side of
    /// 250 and 290 are the row tiers' boundaries.
    @Test(
        "From 220 pt the panel lays out exactly as today",
        arguments: [220.0, 249.99, 250.0, 250.01, 280.8, 289.99, 290.0, 290.01, 337.0, 400.0],
        [false, true]
    )
    func todaysLayoutFrom220(side: Double, isAccessibilitySize: Bool) {
        typealias Layout = NowPlayingSoundLabLayout
        // One type on both sides: #expect compares a Double operand with a
        // CGFloat one as unequal even when the values print the same.
        let side = CGFloat(side)
        let layout = Layout(panelWidth: side)
        #expect(Layout.showsInline(panelSide: side))
        #expect(layout.contentInset == Self.todaysInset(side))
        #expect(layout.artworkRailWidth == Self.todaysRail(side))
        #expect(layout.artworkGutter == 4.0)
        #expect(layout.rowAreaWidth == max(0, side - Self.todaysInset(side) - Self.todaysRail(side) - 4))
        #expect(layout.artworkExposedWidth == side * 0.18)
        #expect(Layout.railCapsuleCount(panelHeight: side) == 12)
        for rowCount in [2, 3] {
            #expect(
                Layout.rowMetrics(
                    panelHeight: side,
                    verticalInset: layout.contentInset,
                    rowCount: rowCount,
                    isAccessibilitySize: isAccessibilitySize
                ) == Self.todaysRows(
                    panelHeight: side,
                    inset: Self.todaysInset(side),
                    rowCount: rowCount,
                    isAccessibilitySize: isAccessibilitySize
                )
            )
        }
    }

    @Test("Settled open, the close target covers the visible artwork, stops where the rows begin, and is at least 44 pt wide")
    func closeTargetSpan() {
        typealias Layout = NowPlayingSoundLabLayout
        for panelWidth in stride(from: Layout.inlineFloor, through: 700, by: 0.25) {
            let layout = Layout(panelWidth: panelWidth)
            let open = layout.artworkHitSpan(panelSide: panelWidth, isSettledOpen: true)
            let message: Comment = "panel \(panelWidth) span \(open)"
            #expect(open.upperBound - open.lowerBound >= Layout.minimumHitTarget - 0.000_1, message)
            #expect(open.lowerBound <= 0, message)
            #expect(open.upperBound >= layout.artworkExposedWidth, message)
            #expect(open.upperBound >= layout.protectedLeadingSpace, message)
            if layout.artworkExposedWidth <= layout.protectedLeadingSpace {
                // The rows begin past the visible artwork: the span ends at them.
                #expect(open.upperBound == layout.protectedLeadingSpace, message)
            }
            #expect(layout.artworkHitSpan(panelSide: panelWidth, isSettledOpen: false) == 0...panelWidth)
        }
    }

    @Test(
        "The close target's fixtures: grown outward on the Closed card, today's rows released on the iPhone, the visible strip on large panels",
        arguments: [
            (side: 156.33, lower: -16.67, upper: 27.33),
            (side: 166.92, lower: -6.08, upper: 37.92),
            (side: 214.24, lower: 0.0, upper: 44.0),
            (side: 280.8, lower: 0.0, upper: 54.544),
            (side: 400.0, lower: 0.0, upper: 72.0)
        ]
    )
    func closeTargetFixtures(side: Double, lower: Double, upper: Double) {
        let side = CGFloat(side)
        let span = NowPlayingSoundLabLayout(panelWidth: side).artworkHitSpan(panelSide: side, isSettledOpen: true)
        #expect(abs(span.lowerBound - lower) < 0.001, "span \(span)")
        #expect(abs(span.upperBound - upper) < 0.001, "span \(span)")
    }
}
