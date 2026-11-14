import Foundation
import OpenCastCore
import Testing

@Suite("Show notes timestamp")
struct ShowNotesTimestampTests {
    @Test("The grammar exposes hours, minutes and seconds as three capture groups")
    func captureGroups() {
        #expect(ShowNotesTimestamp.regex.pattern == ShowNotesTimestamp.pattern)
        #expect(ShowNotesTimestamp.regex.numberOfCaptureGroups == 3)
    }

    @Test("Show-notes timestamps match exactly their digits and resolve to seconds")
    func timestampsMatch() {
        let found = timestamps(in: "(00:02:16) Investing\n8:39 \u{2013} Bloopers\n1:02:33 Topic\n[12:05] Q&A")

        #expect(found.texts == ["00:02:16", "8:39", "1:02:33", "12:05"])
        #expect(found.seconds == [136, 519, 3753, 725])
    }

    @Test(
        "Clock times, fractions, ISO dates, and out-of-range digits are not timestamps",
        arguments: [
            "10:75",
            "60:30",
            "123:45",
            "12:34:56:78",
            "2026-09-06T10:30:00Z",
            "8:39 am",
            "8:39pm",
            "8:39 P.M.",
            "16:9",
            "3:16.5"
        ]
    )
    func nonTimestamps(text: String) {
        #expect(timestamps(in: text).texts.isEmpty)
    }

    @Test("A line of non-timestamps side by side yields no match")
    func nonTimestampsTogether() {
        let text = "10:75 60:30 123:45 12:34:56:78 2026-09-06T10:30:00Z 8:39 am 8:39pm 8:39 P.M. 16:9 3:16.5"
        #expect(timestamps(in: text).texts.isEmpty)
    }

    @Test("A timestamp followed by a word that starts with am still matches")
    func timestampBeforeClockWord() {
        let found = timestamps(in: "8:39 amazing guest")

        #expect(found.texts == ["8:39"])
        #expect(found.seconds == [519])
    }

    @Test("The pattern embedded after two capture groups resolves with a group offset of two")
    func embeddedPattern() throws {
        let expression = try NSRegularExpression(
            pattern: #"^(- )?([\[(]?)"# + ShowNotesTimestamp.pattern + #"[\])]?\s+(\S.*)$"#,
            options: .anchorsMatchLines
        )
        let text = "- 00:00 Intro\n- [05:10] Topic\n(1:02:33) Outro"
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))

        #expect(matches.map { ShowNotesTimestamp.seconds(of: $0, in: text, groupOffset: 2) } == [0, 310, 3753])
        #expect(matches.map { title(of: $0, in: text) } == ["Intro", "Topic", "Outro"])
        #expect(matches.map { ShowNotesTimestamp.seconds(of: $0, in: text) } == [nil, nil, nil])
    }

    @Test("An offset outside the match's groups yields nil instead of trapping", arguments: [1, 2, 10, -3, .max, .min])
    func offsetPastGroups(offset: Int) throws {
        let text = "8:39 Bloopers"
        let match = try #require(ShowNotesTimestamp.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))

        #expect(ShowNotesTimestamp.seconds(of: match, in: text, groupOffset: offset) == nil)
    }

    @Test("A match of an expression with fewer groups yields nil")
    func fewerGroups() throws {
        let text = "8:39"
        let expression = try NSRegularExpression(pattern: #"(\d+):\d+"#)
        let match = try #require(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))

        #expect(ShowNotesTimestamp.seconds(of: match, in: text) == nil)
    }

    private func timestamps(in text: String) -> (texts: [String], seconds: [Int?]) {
        let matches = ShowNotesTimestamp.regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let texts = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return (texts, matches.map { ShowNotesTimestamp.seconds(of: $0, in: text) })
    }

    private func title(of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: match.numberOfRanges - 1), in: text).map { String(text[$0]) }
    }
}
