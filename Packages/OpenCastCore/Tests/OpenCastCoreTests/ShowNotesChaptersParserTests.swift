import Foundation
import OpenCastCore
import Testing

@Suite("Show-notes chapters parser")
struct ShowNotesChaptersParserTests {
    @Test(
        "Each line shape the publisher harvest showed reads as a list",
        arguments: [
            (["00:00 Cold open", "04:30 Meet the guest", "12:05 Wrap up"], [0, 270, 725], ["Cold open", "Meet the guest", "Wrap up"]),
            (["[00:00] Introduction", "[00:31] Welcome", "[03:35] What Are Strengths?"], [0, 31, 215], ["Introduction", "Welcome", "What Are Strengths?"]),
            (
                ["(02:13) - What did Helen do", "(03:00) - What did Michael do", "(05:05) - Customer support"],
                [133, 180, 305],
                ["What did Helen do", "What did Michael do", "Customer support"]
            ),
            (
                ["2:22 \u{2013} The history of Python", "9:41 \u{2013} Why Go", "14:07 \u{2013} Rust"],
                [142, 581, 847],
                ["The history of Python", "Why Go", "Rust"]
            ),
            (["00:00:00 Pre-show", "00:02:23 Intro", "01:05:00 Wrap"], [0, 143, 3900], ["Pre-show", "Intro", "Wrap"])
        ] as [([String], [TimeInterval], [String])]
    )
    func harvestShapes(lines: [String], starts: [TimeInterval], titles: [String]) {
        let chapters = parse(lines)

        #expect(chapters.map(\.startTime) == starts)
        #expect(chapters.map(\.title) == titles)
    }

    @Test("A Timestamps heading with prose around it: the list starts where its first topic does")
    func timestampsHeading() {
        let chapters = parse([
            "Zach Reitano is the co-founder and CEO of Ro.",
            "",
            "Timestamps:",
            "",
            "(00:01:35) Why Healthcare Spending Should Rise",
            "",
            "(00:05:39) Putting Patients in Control",
            "",
            "(00:10:37) Inside Ro's GLP-1 Business",
            "",
            "(01:12:54) The Kindest Thing",
            "",
            "Follow the show on X and LinkedIn."
        ])

        #expect(chapters.map(\.startTime) == [95, 339, 637, 4374])
        #expect(chapters.map(\.title) == [
            "Why Healthcare Spending Should Rise",
            "Putting Patients in Control",
            "Inside Ro's GLP-1 Business",
            "The Kindest Thing"
        ])
    }

    @Test(
        "One bullet, a bracket, or both may come before the timestamp, with spaces inside the bracket",
        arguments: [
            (["- 00:00 Intro", "- 05:00 Topic", "- 10:00 Outro"], [0, 300, 600]),
            (["• 00:00 Intro", "• 05:00 Topic", "• 10:00 Outro"], [0, 300, 600]),
            (["* 00:00 Intro", "* 05:00 Topic", "* 10:00 Outro"], [0, 300, 600]),
            (["1. 00:00 Intro", "2. 05:00 Topic", "3. 10:00 Outro"], [0, 300, 600]),
            (["98. 00:00 Intro", "99. 05:00 Topic", "100. 10:00 Outro"], [0, 300, 600]),
            (["\u{2013} 00:00 Intro", "\u{2014} 05:00 Topic", "- 10:00 Outro"], [0, 300, 600]),
            (["- (00:00) Intro", "- (05:00) Topic", "- (10:00) Outro"], [0, 300, 600]),
            (["( 06:53 ) Intro", "( 30:08 ) Topic", "( 50:32 ) Outro"], [413, 1808, 3032]),
            (["• ( 06:53 ) Intro", "• ( 30:08 ) Topic", "• ( 50:32 ) Outro"], [413, 1808, 3032]),
            (["  [ 0:00 ] Intro", "\t[5:00 ] Topic", " [ 10:00] Outro"], [0, 300, 600])
        ] as [([String], [TimeInterval])]
    )
    func bulletsAndBrackets(lines: [String], starts: [TimeInterval]) {
        let chapters = parse(lines)

        #expect(chapters.map(\.startTime) == starts)
        #expect(chapters.map(\.title) == ["Intro", "Topic", "Outro"])
    }

    @Test("A bullet needs whitespace after it, and two bullets are not one")
    func bulletShapesThatAreNotEntries() {
        #expect(parse(["-00:00 Intro", "-05:00 Topic", "-10:00 Outro"]).isEmpty)
        #expect(parse(["- - 00:00 Intro", "- - 05:00 Topic", "- - 10:00 Outro"]).isEmpty)
        #expect(parse(["1000. 00:00 Intro", "1001. 05:00 Topic", "1002. 10:00 Outro"]).isEmpty)
    }

    @Test("A lone bullet line between entries is splitter residue: it neither ends a block nor counts as an entry")
    func loneBulletLines() {
        let chapters = parse(["-", "0:00 \u{2014} Start", "", "-", "5:00 \u{2014} Middle", "", " \u{2013} ", "10:00 \u{2014} End", "•", "1."])

        #expect(chapters.map(\.startTime) == [0, 300, 600])
        #expect(chapters.map(\.title) == ["Start", "Middle", "End"])
        #expect(parse(["-", "-", "-", "•", "*"]).isEmpty)
        #expect(parse(["00:00 Intro", "-", "05:00 Topic", "-"]).isEmpty)
    }

    @Test("A line-led run of 24-hour clock times reads as chapters: D1 accepts it knowingly")
    func clockTimeRunIsAccepted() {
        let chapters = parse([
            ##"12:10 — "#api Adding 2 new indexes on the feeds table.""##,
            "",
            ##"14:38 — "#api All out brawl with the feed aggregators this morning.""##,
            "",
            ##"17:08 — "Battle is over. The war is ongoing.""##
        ])

        #expect(chapters.map(\.startTime) == [730, 878, 1_028])
        #expect(chapters.map(\.title) == [
            ##""#api Adding 2 new indexes on the feeds table.""##,
            ##""#api All out brawl with the feed aggregators this morning.""##,
            ##""Battle is over. The war is ongoing.""##
        ])
    }

    @Test("Clock times inside prose are not line-led, so they are not chapters")
    func clockTimesInProse() {
        #expect(parse([
            "Mike: 11:30 on Wednesday, Podcast Distribution.",
            "Todd: 10:15 on Thursday, the 15th State of Podcasting",
            "Todd: 11:30 on Thursday, Ads: Delivery and Engagement"
        ]).isEmpty)
    }

    @Test("Clock times with am or pm leading lines are not timestamps")
    func amPmScheduleLines() {
        #expect(parse(["12:00pm - New Podcast Primer", "9:00am - Edison Research", "1:30pm - Artwork talk"]).isEmpty)
        #expect(parse(["- 12:00pm - New Podcast Primer", "- 9:00am - Edison Research", "- 1:30pm - Artwork talk"]).isEmpty)
    }

    @Test(
        "Every separator character may follow a closing bracket, including the bracket alone",
        arguments: [
            ["(00:00): Intro", "(05:00): Topic", "(10:00): Outro"],
            ["[00:00] | Intro", "[05:00] | Topic", "[10:00] | Outro"],
            ["(00:00) \u{2014} Intro", "(05:00) \u{2014} Topic", "(10:00) \u{2014} Outro"],
            ["(00:00)Intro", "(05:00)Topic", "(10:00)Outro"],
            ["[00:00]Intro", "[05:00]Topic", "[10:00]Outro"],
            ["00:00 | Intro", "05:00 | Topic", "10:00 | Outro"],
            ["00:00 \u{2013} Intro", "05:00 - Topic", "10:00 \u{2014} Outro"]
        ]
    )
    func separators(lines: [String]) {
        let chapters = parse(lines)

        #expect(chapters.map(\.startTime) == [0, 300, 600])
        #expect(chapters.map(\.title) == ["Intro", "Topic", "Outro"])
    }

    @Test("A timestamp glued to its title has no separator, so it is not an entry")
    func noSeparator() {
        #expect(parse(["00:00Intro", "05:00Topic", "10:00Outro"]).isEmpty)
    }

    @Test("A bare timestamp followed directly by a colon is not a timestamp under the shared grammar")
    func bareTimestampThenColon() {
        #expect(parse(["00:00: Intro", "05:00: Topic", "10:00: Outro"]).isEmpty)
    }

    @Test("Blank lines between entries keep the block; a prose line between entries ends it")
    func blankAndProseLines() {
        let chapters = parse(["00:00 Intro", "", "", "05:00 Topic", "   ", "\t", "10:00 Outro"])

        #expect(chapters.map(\.startTime) == [0, 300, 600])
        #expect(chapters.map(\.title) == ["Intro", "Topic", "Outro"])
        #expect(parse(["00:00 Intro", "05:00 Topic", "Sponsored by a mattress company", "10:00 Outro", "15:00 End"]).isEmpty)
    }

    @Test("Two entries are not a list; three are")
    func minimumCount() {
        #expect(ShowNotesChaptersParser.minimumChapterCount == 3)
        #expect(parse(["00:00 Intro", "05:00 Topic"]).isEmpty)

        let chapters = parse(["00:00 Intro", "05:00 Topic", "10:00 Outro"])
        #expect(chapters.map(\.startTime) == [0, 300, 600])
        #expect(chapters.map(\.title) == ["Intro", "Topic", "Outro"])
    }

    @Test("One out-of-order entry in the middle of a block is dropped and the rest kept")
    func outOfOrderEntryDropped() {
        let chapters = parse(["0:00 A", "5:00 B", "10:00 C", "2:00 X", "15:00 D", "20:00 E"])

        #expect(chapters.map(\.startTime) == [0, 300, 600, 900, 1_200])
        #expect(chapters.map(\.title) == ["A", "B", "C", "D", "E"])
    }

    @Test(
        "The too-large typo is the entry dropped, and the entries after it survive",
        arguments: [
            (["37:56 A", "50:58 Typo", "44:11 B", "44:52 C", "48:18 D"], [2_276, 2_651, 2_692, 2_898], ["A", "B", "C", "D"]),
            (["0:00 A", "4:00 Typo", "3:04 B", "6:10 C", "9:00 D"], [0, 184, 370, 540], ["A", "B", "C", "D"])
        ] as [([String], [TimeInterval], [String])]
    )
    func tooLargeTypoDropped(lines: [String], starts: [TimeInterval], titles: [String]) {
        let chapters = parse(lines)

        #expect(chapters.map(\.startTime) == starts)
        #expect(chapters.map(\.title) == titles)
    }

    @Test("Of two entries with the same start, the earlier line stays")
    func equalStartKeepsEarlierLine() {
        let chapters = parse(["0:00 A", "1:00 B", "1:00 C", "2:00 D", "3:00 E"])

        #expect(chapters.map(\.startTime) == [0, 60, 120, 180])
        #expect(chapters.map(\.title) == ["A", "B", "D", "E"])
    }

    @Test("A block with no ascending run of three but an ascending selection of three now yields")
    func selectionWithoutAscendingRun() {
        let chapters = parse(["5:00 A", "6:00 B", "1:00 X", "7:00 C"])

        #expect(chapters.map(\.startTime) == [300, 360, 420])
        #expect(chapters.map(\.title) == ["A", "B", "C"])
    }

    @Test("Two lists separated only by blank lines share a block, so the selection mixes them")
    func backToBackListsMix() {
        // The accepted cost of tolerating a typo'd start such as a mid-list 00:00: a second list that goes back to
        // the start stays in the block. Every kept entry is still a real time and title from the same notes.
        let chapters = parse(["0:00 A", "5:00 B", "10:00 C", "", "0:00 D", "6:00 E", "12:00 F", "18:00 G"])

        #expect(chapters.map(\.startTime) == [0, 300, 360, 720, 1_080])
        #expect(chapters.map(\.title) == ["A", "B", "E", "F", "G"])
    }

    @Test("Highlights followed by the full list with only blank lines between yield the full list")
    func highlightsThenFullList() {
        let fullList = [
            (0, "Intro"), (130, "Python 2 to 3"), (413, "Python, Go and Rust"), (515, "Rust for startups"),
            (748, "Choosing a language"), (1_353, "Unified code bases"), (1_459, "AI coding tools"),
            (1_808, "Changing his mind"), (2_284, "Languages in an AI future"), (2_533, "Working more"),
            (2_861, "Error handling at Sentry"), (3_032, "Language choice"), (3_362, "The SDLC"),
            (3_858, "Language designers"), (3_940, "Startups"), (4_299, "Rapid fire round")
        ]
        let lines = ["6:53 A", "", "30:08 B", "", "50:32 C", ""] + fullList.map { "\(clock($0.0)) \($0.1)" }
        let chapters = parse(lines)

        #expect(chapters.map(\.startTime) == fullList.map { TimeInterval($0.0) })
        #expect(chapters.map(\.title) == fullList.map(\.1))
    }

    @Test("A first entry that is itself the too-large typo gives way to the list after it")
    func firstEntryIsTheTypo() {
        let chapters = parse(["10:00 X", "1:35 A", "5:39 B", "10:37 C"])

        #expect(chapters.map(\.startTime) == [95, 339, 637])
        #expect(chapters.map(\.title) == ["A", "B", "C"])
    }

    @Test("The duration bound comes before the selection, so a typo far past the end cannot anchor it")
    func durationBeforeSelection() {
        let lines = ["0:00 A", "5:00 B", "50:00 X", "51:00 Y", "52:00 Z", "10:00 C", "15:00 D"]

        #expect(parse(lines, duration: 1_800).map(\.startTime) == [0, 300, 600, 900])
        #expect(parse(lines, duration: 1_800).map(\.title) == ["A", "B", "C", "D"])
        #expect(parse(lines).map(\.startTime) == [0, 300, 3_000, 3_060, 3_120])
    }

    @Test("A prose line still ends a block: two blocks are never joined")
    func proseEndsBlock() {
        #expect(parse(["0:00 A", "1:00 B", "Sponsored by a mattress company", "2:00 C", "3:00 D"]).isEmpty)
    }

    @Test("Entries in descending order yield nothing")
    func descendingEntries() {
        #expect(parse(["10:00 A", "5:00 B", "1:00 C", "0:30 D"]).isEmpty)
    }

    @Test("The longest selection wins over an earlier block's shorter one")
    func longestSelectionWins() {
        let chapters = parse(["0:00 A", "1:00 B", "2:00 C", "Jump to:", "0:00 D", "1:00 E", "2:30:00 Z", "2:00 F", "3:00 G"])

        #expect(chapters.map(\.title) == ["D", "E", "F", "G"])
        #expect(chapters.map(\.startTime) == [0, 60, 120, 180])
    }

    @Test("Selections of equal length keep the first block")
    func tieKeepsFirstBlock() {
        let chapters = parse(["0:00 A", "1:00 B", "2:00 C", "Jump to:", "0:00 D", "1:00 E", "2:30:00 Z", "2:00 F"])

        #expect(chapters.map(\.title) == ["A", "B", "C"])
    }

    @Test("An entry exactly at the duration is kept; one past it is dropped")
    func durationDropsEntriesPastIt() {
        let lines = ["0:00 A", "1:00 B", "2:00 C", "3:00 D", "4:00 E"]

        #expect(parse(lines, duration: 180).map(\.title) == ["A", "B", "C", "D"])
        #expect(parse(lines, duration: 179).map(\.title) == ["A", "B", "C"])
        #expect(parse(lines, duration: 179.5).map(\.title) == ["A", "B", "C"])
        #expect(parse(lines, duration: 240).map(\.startTime) == [0, 60, 120, 180, 240])
        #expect(parse(lines, duration: 239).map(\.startTime) == [0, 60, 120, 180])
    }

    @Test("A block the duration leaves with two entries yields nothing; the third exactly at the duration keeps it")
    func durationLeavesTwo() {
        let lines = ["0:00 A", "1:00 B", "2:00 C", "3:00 D"]

        #expect(parse(lines, duration: 119).isEmpty)
        #expect(parse(lines, duration: 120).map(\.title) == ["A", "B", "C"])
    }

    @Test("A shorter block that keeps three beats a longer one the duration cuts below three")
    func durationDecidesWinner() {
        let lines = ["0:00 D", "1:00 E", "10:00 F", "20:00 G", "30:00 H", "Highlights:", "0:00 A", "1:00 B", "2:00 C"]

        #expect(parse(lines).map(\.title) == ["D", "E", "F", "G", "H"])
        #expect(parse(lines, duration: 120).map(\.title) == ["A", "B", "C"])
        #expect(parse(lines, duration: 119).isEmpty)
    }

    @Test(
        "A duration that is missing, zero, negative or not finite drops nothing",
        arguments: [nil, 0, -1, .nan, .infinity, -.infinity] as [TimeInterval?]
    )
    func unknownDuration(duration: TimeInterval?) {
        let chapters = parse(["0:00 A", "1:00:00 B", "99:59:59 C"], duration: duration)

        #expect(chapters.map(\.startTime) == [0, 3_600, 359_999])
        #expect(chapters.map(\.title) == ["A", "B", "C"])
    }

    @Test(
        "Lines that carry timestamps without leading with an entry yield nothing",
        arguments: [
            ["at 12:34 she explains the plan", "and at 15:00 he disagrees", "by 20:00 they settle it"],
            ["Introduction [00:00]", "Drive action with chapters [01:44]", "Wrap up [08:03]"],
            ["Intro \u{2014} 0:00", "Topic \u{2014} 5:00", "Outro \u{2014} 10:00"],
            ["0:00 \u{2013} 5:12 Intro", "5:12 \u{2013} 10:00 Topic", "10:00 \u{2013} 15:00 Outro"],
            ["0:00-5:12 Intro", "5:12-10:00 Topic", "10:00-15:00 Outro"],
            ["(0:00) - (5:12) Intro", "(5:12) - (10:00) Topic", "(10:00) - (15:00) Outro"],
            ["[0:00 - 5:12] Intro", "[5:12 - 10:00] Topic", "[10:00 - 15:00] Outro"],
            ["8:30 pm doors open", "9:00 pm first set", "10:15 pm encore"],
            ["00:00", "Intro", "05:00", "Topic", "10:00", "Outro"],
            ["00:00", "", "05:00", "", "10:00"]
        ]
    )
    func nonEntries(lines: [String]) {
        #expect(parse(lines).isEmpty)
    }

    @Test(
        "A dash or the word to before a second time makes the line a range, whatever follows that time, so it is not an entry",
        arguments: [
            ["0:00 - 1:00: Intro", "1:00 - 2:00: Topic", "2:00 - 3:00: Outro"],
            ["0:00 to 1:00 Intro", "1:00 to 2:00 Topic", "2:00 to 3:00 Outro"],
            ["0:00 TO 1:00 Intro", "1:00 To 2:00 Topic", "2:00 tO 3:00 Outro"],
            ["(0:00) - (1:00): Intro", "(1:00) - (2:00): Topic", "(2:00) - (3:00): Outro"],
            ["(0:00) to (1:00) Intro", "(1:00) to (2:00) Topic", "(2:00) to (3:00) Outro"],
            ["00:00 - 9:30pm Doors", "05:00 - 10:00pm Set", "10:00 - 11:15 pm Encore"],
            ["0:00:00 \u{2013} 0:10:00: Intro", "0:10:00 \u{2013} 01:00:00.5 Topic", "1:00:00 \u{2013} 1:30:000 Outro"],
            ["(0:00 - 1:00) Intro", "(1:00 - 2:00) Topic", "(2:00 - 3:00) Outro"],
            ["[00:00 \u{2013} 05:12] Intro", "[05:12 \u{2013} 10:00] Topic", "[10:00 \u{2013} 15:00] Outro"],
            ["0:00-1:00 Intro", "1:00-2:00 Topic", "2:00-3:00 Outro"],
            ["( 0:00 ) - ( 1:00 ) Intro", "( 1:00 ) - ( 2:00 ) Topic", "( 2:00 ) - ( 3:00 ) Outro"],
            ["0:00 -- 1:00 Intro", "1:00 -- 2:00 Topic", "2:00 -- 3:00 Outro"]
        ]
    )
    func rangesWhateverFollowsTheirEnd(lines: [String]) {
        #expect(parse(lines).isEmpty)
    }

    @Test(
        "A title that only mentions a later time, opens with a number that is not a time, or opens with the word to stays an entry",
        arguments: [
            (["00:00 Intro (runs 2:15)", "05:00 Topic (runs 3:40)", "10:00 Outro (runs 1:05)"], ["Intro (runs 2:15)", "Topic (runs 3:40)", "Outro (runs 1:05)"]),
            (["00:00 10 things we learned", "05:00 3 ways to start", "10:00 100:1 odds"], ["10 things we learned", "3 ways to start", "100:1 odds"]),
            (["00:00 to be continued", "05:00 To 10 and beyond", "10:00 Tomorrow at 9:30"], ["to be continued", "To 10 and beyond", "Tomorrow at 9:30"])
        ] as [([String], [String])]
    )
    func titlesThatAreNotRanges(lines: [String], titles: [String]) {
        let chapters = parse(lines)

        #expect(chapters.map(\.startTime) == [0, 300, 600])
        #expect(chapters.map(\.title) == titles)
    }

    @Test("A title that begins with a time, with no dash or to between the two times, is an entry that keeps its time")
    func timeLedTitles() {
        let chapters = parse([
            "(00:01:35) 9:30pm bedtime routine",
            "05:00 3:16 and the gospel",
            "10:00 | 12:30 lunch break",
            "(15:00): 5:00 AM wake-ups"
        ])

        #expect(chapters.map(\.startTime) == [95, 300, 600, 900])
        #expect(chapters.map(\.title) == ["9:30pm bedtime routine", "3:16 and the gospel", "12:30 lunch break", "5:00 AM wake-ups"])
    }

    @Test("A time-led title in the middle of a list no longer cuts it in two")
    func timeLedTitleInsideList() {
        let chapters = parse(["00:00 Intro", "05:00 Mornings", "10:00 9:30pm bedtime routine", "15:00 Sleep", "20:00 Outro"])

        #expect(chapters.map(\.startTime) == [0, 300, 600, 900, 1_200])
        #expect(chapters.map(\.title) == ["Intro", "Mornings", "9:30pm bedtime routine", "Sleep", "Outro"])
    }

    @Test("M:SS, MM:SS, H:MM:SS and HH:MM:SS mix in one list across the hour")
    func timestampFormats() {
        let chapters = parse(["0:30 A", "12:45 B", "58:30 C", "1:02:10 D", "01:10:00 E"])

        #expect(chapters.map(\.startTime) == [30, 765, 3_510, 3_730, 4_200])
        #expect(chapters.map(\.title) == ["A", "B", "C", "D", "E"])
    }

    @Test("A long title is cut to the decoder's title length")
    func longTitle() {
        let long = (0..<250).map { String($0 % 10) }.joined()
        let chapters = parse(["00:00 Intro", "05:00 \(long)", "10:00 Outro"])

        #expect(chapters.count == 3)
        #expect(chapters[1].title == String(long.prefix(PublisherChaptersDocumentDecoder.maximumTitleLength)))
        #expect(chapters[1].title.count == 200)
    }

    @Test("A title of only separators is not an entry, so its line ends the block")
    func separatorOnlyTitle() {
        #expect(parse(["00:00 -", "05:00 \u{2013}", "10:00 | :"]).isEmpty)
        #expect(parse(["00:00 Intro", "05:00 -", "10:00 Topic", "15:00 Outro"]).isEmpty)
    }

    @Test("A title that trims to nothing is not an entry, so its line ends the run")
    func titleTrimsToNothing() {
        #expect(parse(["0:00 \u{200B}", "1:00 \u{200B}", "2:00 \u{200B}"]).isEmpty)
        #expect(parse(["0:00 Intro", "1:00 \u{200B}", "2:00 Outro"]).isEmpty)
    }

    @Test("Zero-width spaces around a title are trimmed and its text is kept")
    func zeroWidthSpacesAroundTitle() {
        let chapters = parse(["0:00 \u{200B}Intro\u{200B}", "1:00 \u{200B}Topic\u{200B}", "2:00 \u{200B}Outro\u{200B}"])

        #expect(chapters.map(\.startTime) == [0, 60, 120])
        #expect(chapters.map(\.title) == ["Intro", "Topic", "Outro"])
    }

    @Test("Trailing whitespace is trimmed from a title")
    func titleTrimmed() {
        #expect(parse(["00:00 Intro  ", "05:00 Topic\t", "10:00 Outro \u{00A0}"]).map(\.title) == ["Intro", "Topic", "Outro"])
    }

    @Test("CRLF and bare CR split lines the way LF does")
    func lineEndings() {
        let lines = ["00:00 A", "05:00 B", "Sponsor", "10:00 C", "", "15:00 D", "20:00 E"]
        let expected = parse(lines)

        #expect(expected.map(\.title) == ["C", "D", "E"])
        #expect(ShowNotesChaptersParser.chapters(in: lines.joined(separator: "\r\n"), duration: nil) == expected)
        #expect(ShowNotesChaptersParser.chapters(in: lines.joined(separator: "\r"), duration: nil) == expected)
    }

    @Test("Ids are positions from zero and no chapter has an end")
    func idsAndEnds() {
        let chapters = parse(["Jump to:", "01:00 A", "02:00 B", "03:00 C", "04:00 D"])

        #expect(chapters.map(\.id) == [0, 1, 2, 3])
        #expect(chapters.allSatisfy { $0.endTime == nil })
    }

    @Test("A list longer than the decoder's chapter cap keeps its earliest entries")
    func chapterCap() {
        let lines = (0..<5_000).map { "\(clock($0)) Entry \($0)" }
        let chapters = parse(lines)

        #expect(chapters.count == PublisherChaptersDocumentDecoder.maximumChapterCount)
        #expect(chapters.map(\.id) == Array(0..<1_000))
        #expect(chapters.map(\.startTime) == (0..<1_000).map(TimeInterval.init))
        #expect(chapters.first?.title == "Entry 0")
        #expect(chapters.last?.title == "Entry 999")
    }

    @Test("A two-megabyte line returns without trapping, alone or as a title", .timeLimit(.minutes(1)))
    func hugeLine() {
        let filler = String(repeating: "- ( 1:00 ) - 12:34 [", count: 100_000)
        let spaces = String(repeating: " ", count: 2_000_000)
        #expect(filler.utf8.count == 2_000_000)

        #expect(parse(["00:00 " + filler]).isEmpty)
        #expect(parse([filler]).isEmpty)
        #expect(parse([spaces + "x"]).isEmpty)
        #expect(parse(["- " + spaces + "(" + spaces + "x"]).isEmpty)
        #expect(parse(["0:00 (" + spaces + "x"]).isEmpty)
        #expect(parse(["0:00 (to" + spaces + "(" + spaces + "x"]).isEmpty)
        #expect(parse(["0:00" + spaces + "-" + spaces + "x"]).isEmpty)
        #expect(parse(["0:00" + spaces + ")" + spaces + "to" + spaces + "(" + spaces + "x"]).isEmpty)

        let chapters = parse(["00:00 Intro", "05:00 x" + filler, "10:00 Outro"])
        #expect(chapters.map(\.startTime) == [0, 300, 600])
        #expect(chapters[1].title == String(("x" + filler).prefix(PublisherChaptersDocumentDecoder.maximumTitleLength)))
    }

    @Test("A hundred thousand short lines return the first of many equal blocks")
    func manyLines() {
        let lines = (0..<100_000).map { ["0:00 A", "0:01 B", "0:02 C", "x"][$0 % 4] }
        let chapters = parse(lines)

        #expect(chapters.map(\.title) == ["A", "B", "C"])
        #expect(chapters.map(\.startTime) == [0, 1, 2])
    }

    @Test("A hundred thousand entries in descending order select one each and yield nothing", .timeLimit(.minutes(1)))
    func manyDescendingEntries() {
        let lines = (0..<100_000).map { "\(clock(99_999 - $0)) Entry \($0)" }

        #expect(parse(lines).isEmpty)
    }

    @Test("A hundred thousand entries alternating high and low keep the ascending lows, capped", .timeLimit(.minutes(1)))
    func manyAlternatingEntries() {
        let lines = (0..<100_000).map { $0.isMultiple(of: 2) ? "\(clock(100_000 + $0 / 2)) High \($0 / 2)" : "\(clock($0 / 2)) Low \($0 / 2)" }
        let chapters = parse(lines)

        #expect(chapters.count == PublisherChaptersDocumentDecoder.maximumChapterCount)
        #expect(chapters.map(\.startTime) == (0..<1_000).map(TimeInterval.init))
        #expect(chapters.first?.title == "Low 0")
        #expect(chapters.last?.title == "Low 999")
    }

    @Test("A hundred thousand ascending entries return the first thousand", .timeLimit(.minutes(1)))
    func manyAscendingEntries() {
        let lines = (0..<100_000).map { "\(clock($0)) Entry \($0)" }
        let chapters = parse(lines)

        #expect(chapters.count == PublisherChaptersDocumentDecoder.maximumChapterCount)
        #expect(chapters.map(\.startTime) == (0..<1_000).map(TimeInterval.init))
        #expect(chapters.first?.title == "Entry 0")
        #expect(chapters.last?.title == "Entry 999")
    }

    @Test("A hundred thousand entries with one start keep only the first, and one entry is not three", .timeLimit(.minutes(1)))
    func manyEntriesWithOneStart() {
        // An equal start never replaces a pile's top, so the selection holds the first entry alone.
        let lines = (0..<100_000).map { "1:00 Entry \($0)" }

        #expect(parse(lines).isEmpty)
    }

    @Test("Empty text and text of only line breaks yield nothing", arguments: ["", "\n", String(repeating: "\n", count: 10_000), "\r\n\r\n\r", " \n\t\n "])
    func emptyText(text: String) {
        #expect(ShowNotesChaptersParser.chapters(in: text, duration: nil).isEmpty)
        #expect(ShowNotesChaptersParser.chapters(in: text, duration: 60).isEmpty)
    }

    private func parse(_ lines: [String], duration: TimeInterval? = nil) -> [EpisodeChapter] {
        ShowNotesChaptersParser.chapters(in: lines.joined(separator: "\n"), duration: duration)
    }

    private func clock(_ seconds: Int) -> String {
        let minutes = seconds / 60 % 60
        let remainder = seconds % 60
        return "\(seconds / 3_600):\(minutes < 10 ? "0" : "")\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }
}
