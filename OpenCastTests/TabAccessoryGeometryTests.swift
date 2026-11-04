import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// The accessory frames below are fixtures shaped like the measured ones
/// (lane SHELL's Closed capsule at (50, 602) 290×56 in a 466×678 window with
/// a 34 pt bottom inset and an 84 pt rail; S1's pinned-iPhone capsule at
/// (21, 731) 360×56 over a hub whose frame ends at 735), not constants the
/// code knows.
@Suite("Tab accessory geometry and bottom clearance")
struct TabAccessoryGeometryTests {
    private static let capsule = CGRect(x: 50, y: 602, width: 290, height: 56)
    /// The content column above the home indicator, with no accessory inset.
    private static let safeColumn = CGRect(x: 0, y: 0, width: 382, height: 644)
    private static let phoneCapsule = CGRect(x: 21, y: 731, width: 360, height: 56)
    private static let phoneHub = CGRect(x: 0, y: 116, width: 402, height: 619)

    @Test("A shown accessory takes the reported placement; none reported is undefined")
    func placementStates() {
        #expect(TabAccessoryGeometry(placement: .expanded, frame: Self.capsule) == .expanded(frame: Self.capsule))
        #expect(TabAccessoryGeometry(placement: .inline, frame: Self.capsule) == .inline(frame: Self.capsule))
        #expect(TabAccessoryGeometry(placement: nil, frame: Self.capsule) == .undefined(frame: Self.capsule))
        #expect(TabAccessoryGeometry.absent.frame == nil)
    }

    @Test(
        "A frame without a positive, finite area is not a measurement",
        arguments: [
            CGRect.zero,
            CGRect(x: 50, y: 602, width: 290, height: 0),
            CGRect(x: 50, y: 602, width: -290, height: 56),
            CGRect.null,
            CGRect.infinite,
            CGRect(x: CGFloat.nan, y: 602, width: 290, height: 56)
        ]
    )
    func unmeasuredFrames(frame: CGRect) {
        let geometry = TabAccessoryGeometry(placement: .expanded, frame: frame)
        #expect(geometry.frame == nil)
        #expect(geometry.bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 0)
    }

    @Test("No accessory, or one not measured yet, needs no clearance, row gap or not")
    func nothingToClear() {
        #expect(TabAccessoryGeometry.absent.bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 0)
        #expect(TabAccessoryGeometry.undefined(frame: nil).bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 0)
        #expect(TabAccessoryGeometry.expanded(frame: Self.capsule).bottomClearance(over: nil, rowSpacing: 18) == 0)
    }

    @Test("The capsule's depth into the frame is measured, never a constant")
    func depthFollowsFrame() {
        // Beside a rail, with no system accessory inset: 644 - 602 = 42.
        #expect(TabAccessoryGeometry.expanded(frame: Self.capsule).bottomClearance(over: Self.safeColumn, rowSpacing: 0) == 42)
        #expect(TabAccessoryGeometry.undefined(frame: Self.capsule).bottomClearance(over: Self.safeColumn, rowSpacing: 0) == 42)
        for top in stride(from: 560.0, through: 640.0, by: 10) {
            let frame = CGRect(x: 50, y: top, width: 290, height: 44)
            #expect(TabAccessoryGeometry.expanded(frame: frame).bottomClearance(over: Self.safeColumn, rowSpacing: 0) == 644 - top)
        }
        // A fractional depth rounds up, so no sliver of a row stays under it.
        let fractional = CGRect(x: 50, y: 601.4, width: 290, height: 56)
        #expect(TabAccessoryGeometry.expanded(frame: fractional).bottomClearance(over: Self.safeColumn, rowSpacing: 0) == 43)
    }

    @Test("The last row rests one row gap above the capsule: depth plus the row spacing")
    func rowGapAboveTheCapsule() {
        // The pinned iPhone's hub: 4 pt of depth, the compact row gap 18: 22.
        #expect(TabAccessoryGeometry.expanded(frame: Self.phoneCapsule).bottomClearance(over: Self.phoneHub, rowSpacing: 0) == 4)
        #expect(TabAccessoryGeometry.expanded(frame: Self.phoneCapsule).bottomClearance(over: Self.phoneHub, rowSpacing: 18) == 22)
        let clearance = TabAccessoryGeometry.expanded(frame: Self.capsule).bottomClearance(over: Self.safeColumn, rowSpacing: 18)
        let lastRowBottom = Double(Self.safeColumn.maxY) - clearance
        #expect(lastRowBottom == Double(Self.capsule.minY) - 18)
    }

    @Test("A gap the system already leaves below the frame counts toward the row gap, never twice")
    func systemGapCountsOnce() {
        // A4 (Closed): the Inbox list's frame ended at 586, 16 pt above the capsule's 602.
        let closedList = CGRect(x: 0, y: 0, width: 382, height: 586)
        let capsule = TabAccessoryGeometry.expanded(frame: Self.capsule)
        #expect(capsule.bottomClearance(over: closedList, rowSpacing: 0) == 0)
        #expect(capsule.bottomClearance(over: closedList, rowSpacing: 18) == 2)
        #expect(capsule.bottomClearance(over: closedList, rowSpacing: 16) == 0)
        #expect(capsule.bottomClearance(over: closedList, rowSpacing: 12) == 0)
        // An inline accessory inside a bottom bar, 6 pt below the frame.
        let inline = TabAccessoryGeometry.inline(frame: CGRect(x: 60, y: 650, width: 280, height: 30))
        #expect(inline.bottomClearance(over: Self.safeColumn, rowSpacing: 0) == 0)
        #expect(inline.bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 12)
    }

    @Test("An accessory beside the frame, or above it, needs no clearance")
    func disjointAccessory() {
        let besideViewport = CGRect(x: 400, y: 602, width: 290, height: 56)
        #expect(TabAccessoryGeometry.expanded(frame: besideViewport).bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 0)
        let aboveViewport = CGRect(x: 50, y: -100, width: 290, height: 56)
        #expect(TabAccessoryGeometry.expanded(frame: aboveViewport).bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 0)
    }

    @Test("The clearance never exceeds the frame, rounding included")
    func clearanceIsBounded() {
        let tall = CGRect(x: 0, y: -100, width: 382, height: 900)
        #expect(TabAccessoryGeometry.expanded(frame: tall).bottomClearance(over: Self.safeColumn, rowSpacing: 18) == 644)
        let fractionalViewport = CGRect(x: 0, y: 0, width: 382, height: 100.2)
        #expect(TabAccessoryGeometry.expanded(frame: tall).bottomClearance(over: fractionalViewport, rowSpacing: 0) == 100.2)
    }

    /// Each consumer's row gap, as it passes it (RULING 13): the three grids
    /// their metrics' row spacing, the episode page and the Help topic (the
    /// one ScrollView subscreen) their section spacing, the Lists and Forms
    /// (whose rows abut) the shell's row gap for the width class.
    @Test("Every consumer's row gap and its clearance on the pinned iPhone", arguments: [false, true])
    func consumerRowGaps(isAccessibilitySize: Bool) {
        let phoneGrid = LibraryGridMetrics.resolve(containerWidth: 402, isCompact: true, isAccessibilitySize: isAccessibilitySize)
        let wideGrid = LibraryGridMetrics.resolve(containerWidth: 1032, isCompact: false, isAccessibilitySize: isAccessibilitySize)
        let consumers: [(name: String, rowSpacing: Double)] = [
            ("Library grid", phoneGrid.rowSpacing),
            ("grouped Inbox grid", phoneGrid.rowSpacing),
            ("Playlists grid", phoneGrid.rowSpacing),
            ("Settings hub", LibraryGridMetrics.rowSpacing(isCompact: true)),
            ("Settings subscreens", LibraryGridMetrics.rowSpacing(isCompact: true)),
            ("show page", LibraryGridMetrics.rowSpacing(isCompact: true)),
            ("playlist", LibraryGridMetrics.rowSpacing(isCompact: true)),
            ("smart playlist", LibraryGridMetrics.rowSpacing(isCompact: true)),
            ("episode", EpisodeDetailView.contentSpacing),
            ("Help topic", HelpTopicView.blockSpacing)
        ]
        let capsule = TabAccessoryGeometry.expanded(frame: Self.phoneCapsule)
        for consumer in consumers {
            let expected = switch consumer.name {
            case "episode": 28.0
            case "Help topic": 24.0
            default: 22.0
            }
            #expect(capsule.bottomClearance(over: Self.phoneHub, rowSpacing: consumer.rowSpacing) == expected, "\(consumer.name)")
            #expect(TabAccessoryGeometry.absent.bottomClearance(over: Self.phoneHub, rowSpacing: consumer.rowSpacing) == 0)
        }
        // The shell's row gap is the grids' own, in both width classes.
        #expect(LibraryGridMetrics.rowSpacing(isCompact: true) == phoneGrid.rowSpacing)
        #expect(LibraryGridMetrics.rowSpacing(isCompact: false) == wideGrid.rowSpacing)
        #expect(LibraryGridMetrics.rowSpacing(isCompact: false) == 24)
    }
}
