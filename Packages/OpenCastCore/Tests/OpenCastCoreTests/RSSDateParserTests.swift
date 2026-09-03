import Foundation
import Testing
@testable import OpenCastCore

@Suite("RSS date parsing")
struct RSSDateParserTests {
    @Test("Parses Security Now PDT item dates")
    func parsesSecurityNowPDTDate() {
        #expect(RSSDateParser.parse("Tue, 30 Jun 2026 18:43:36 PDT")?.timeIntervalSince1970 == 1_782_870_216)
    }

    @Test("Parses PST offset")
    func parsesPSTDate() {
        #expect(RSSDateParser.parse("Tue, 30 Jun 2026 18:43:36 PST")?.timeIntervalSince1970 == 1_782_873_816)
    }

    @Test("Parses GMT and UTC offsets")
    func parsesGMTAndUTCDate() {
        #expect(RSSDateParser.parse("Sun, 06 Nov 1994 08:49:37 GMT")?.timeIntervalSince1970 == 784_111_777)
        #expect(RSSDateParser.parse("Sun, 06 Nov 1994 08:49:37 UTC")?.timeIntervalSince1970 == 784_111_777)
    }

    @Test(
        "Parses lowercase and mixed-case time zone names",
        arguments: [
            ("Mon, 15 Jan 2024 10:00:00 gmt", 1_705_312_800),
            ("Mon, 15 Jan 2024 10:00:00 Est", 1_705_330_800),
            ("Tue, 30 Jun 2026 18:43:36 pdt", 1_782_870_216),
            ("Sun, 06 Nov 1994 08:49:37 z", 784_111_777)
        ] as [(String, Double)]
    )
    func parsesCaseInsensitiveTimeZoneNames(rawValue: String, expected: Double) {
        #expect(RSSDateParser.parse(rawValue)?.timeIntervalSince1970 == expected)
    }

    @Test("Parses numeric time zones")
    func parsesNumericTimeZoneDate() {
        #expect(RSSDateParser.parse("Sun, 5 Jun 2016 01:51:07 -0700")?.timeIntervalSince1970 == 1_465_116_667)
    }

    @Test("Trims whitespace")
    func trimsWhitespace() {
        #expect(RSSDateParser.parse("  Tue, 30 Jun 2026 18:43:36 PDT \n")?.timeIntervalSince1970 == 1_782_870_216)
    }

    @Test("Rejects empty and malformed dates")
    func rejectsEmptyAndMalformedDates() {
        #expect(RSSDateParser.parse("") == nil)
        #expect(RSSDateParser.parse("not a date") == nil)
    }

    @Test("Rejects pre-1970 dates")
    func rejectsPre1970Dates() {
        #expect(RSSDateParser.parse("Thu, 01 Jan 1960 00:00:00 GMT") == nil)
    }

    @Test(
        "Keeps ISO8601 fallback parity",
        arguments: [
            ("1994-11-06T08:49:37Z", 784_111_777),
            ("2016-06-05T01:51:07-07:00", 1_465_116_667),
            ("2026-04-08T12:00:00+00:00", 1_775_649_600)
        ] as [(String, Double)]
    )
    func keepsISO8601FallbackParity(rawValue: String, expected: Double) {
        #expect(RSSDateParser.parse(rawValue)?.timeIntervalSince1970 == expected)
    }

    @Test("Parses fractional-second ISO8601 dates")
    func parsesFractionalSecondISO8601Dates() {
        #expect(RSSDateParser.parse("1994-11-06T08:49:37.250Z")?.timeIntervalSince1970 == 784_111_777.25)
        #expect(RSSDateParser.parse("2016-06-05T01:51:07.500-07:00")?.timeIntervalSince1970 == 1_465_116_667.5)
    }
}
