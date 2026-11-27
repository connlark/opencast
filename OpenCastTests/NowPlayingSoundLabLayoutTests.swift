import SwiftUI
import Testing
@testable import OpenCast

@Suite("Sound Lab row fit")
struct NowPlayingSoundLabLayoutTests {
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
        // The threshold's measured inputs must still hold on this runtime.
        #expect(switchWidth <= NowPlayingSoundLabLayout.systemSwitchWidth, "switch \(switchWidth)")
        #expect(titleWidth <= NowPlayingSoundLabLayout.voiceBoostTitleWidth, "title \(titleWidth)")
    }

    @MainActor
    @Test("Idle action rows fit the threshold at the default text size", arguments: ["Skip Promos & Ads", "View Transcript"])
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

    // MARK: The inline floor and the narrow rail

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
