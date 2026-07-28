import Foundation
@testable import OpenCastCore
import Testing

@Suite("Duration parser")
struct DurationParserTests {
    @Test(
        "Parses valid durations and rejects invalid values",
        arguments: [
            ("1:02:03", 3_723),
            ("02:03", 123),
            ("90", 90),
            (" 90.5 ", 90.5),
            ("garbage", nil),
            ("1:2:3:4", nil),
            ("nan", nil),
            ("inf", nil),
            ("-5", nil),
            ("1:-30", nil),
            ("1::30", nil)
        ] as [(String, TimeInterval?)]
    )
    func parsesDuration(value: String, expected: TimeInterval?) {
        #expect(DurationParser.parse(value) == expected)
    }
}
