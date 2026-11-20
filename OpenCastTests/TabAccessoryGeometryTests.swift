import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@Suite("Tab accessory geometry and bottom clearance")
struct TabAccessoryGeometryTests {
    private static let capsule = CGRect(x: 50, y: 602, width: 290, height: 56)
    private static let safeColumn = CGRect(x: 0, y: 0, width: 382, height: 644)
    private static let phoneCapsule = CGRect(x: 21, y: 731, width: 360, height: 56)
    private static let phoneHub = CGRect(x: 0, y: 116, width: 402, height: 619)

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
        // A fractional depth rounds up, so no sliver of a row stays under it.
        let fractional = CGRect(x: 50, y: 601.4, width: 290, height: 56)
        #expect(TabAccessoryGeometry.expanded(frame: fractional).bottomClearance(over: Self.safeColumn, rowSpacing: 0) == 43)
    }

    @Test("The last row rests one row gap above the capsule: depth plus the row spacing")
    func rowGapAboveTheCapsule() {
        // The pinned iPhone's hub: 4 pt of depth, the compact row gap 18: 22.
        #expect(TabAccessoryGeometry.expanded(frame: Self.phoneCapsule).bottomClearance(over: Self.phoneHub, rowSpacing: 0) == 4)
        #expect(TabAccessoryGeometry.expanded(frame: Self.phoneCapsule).bottomClearance(over: Self.phoneHub, rowSpacing: 18) == 22)
    }

    @Test("A gap the system already leaves below the frame counts toward the row gap, never twice")
    func systemGapCountsOnce() {
        // The Inbox list's frame ends 16 pt above the capsule.
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
}
