import SwiftUI
import Testing
@testable import OpenCast

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
}
