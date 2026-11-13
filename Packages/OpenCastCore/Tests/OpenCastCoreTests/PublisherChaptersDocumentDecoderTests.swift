import Foundation
import OpenCastCore
import Testing

@Suite("Publisher chapters document decoding")
struct PublisherChaptersDocumentDecoderTests {
    @Test("Decodes the spec sample shape, ignoring img, url, location and unknown keys")
    func decodesSpecSampleShape() throws {
        let chapters = try decode(
            """
            {
              "version": "1.2.0",
              "author": "John Doe",
              "title": "Episode 7 - Making Progress",
              "podcastName": "John's Cool Podcast",
              "description": "A description of this episode",
              "fileName": "/some/path/to/file.mp3",
              "waypoints": false,
              "chapters": [
                { "startTime": 0, "title": "Intro" },
                { "startTime": 168, "title": "Hearing Aids", "img": "https://example.com/images/hearing_aids.jpg" },
                {
                  "startTime": 260,
                  "endTime": 410.5,
                  "title": "Progressive Lenses",
                  "url": "https://example.com/lenses",
                  "img": "https://example.com/images/lenses.jpg"
                },
                { "startTime": 410.5, "title": "Sponsor Read", "toc": false },
                {
                  "startTime": 595.25,
                  "title": "Eiffel Tower",
                  "toc": true,
                  "location": { "name": "Eiffel Tower, Paris", "geo": "geo:48.858093,2.294694" }
                }
              ]
            }
            """
        )

        #expect(chapters == [
            EpisodeChapter(id: 0, title: "Intro", startTime: 0),
            EpisodeChapter(id: 1, title: "Hearing Aids", startTime: 168),
            EpisodeChapter(id: 2, title: "Progressive Lenses", startTime: 260, endTime: 410.5),
            EpisodeChapter(id: 3, title: "Eiffel Tower", startTime: 595.25)
        ])
    }

    @Test("A document without a version decodes")
    func decodesDocumentWithoutVersion() throws {
        let chapters = try decode(#"{"chapters":[{"startTime":5,"title":"Only"}]}"#)

        #expect(chapters == [EpisodeChapter(id: 0, title: "Only", startTime: 5)])
    }

    @Test("Sorts unsorted starts and assigns positional ids")
    func sortsUnsortedStarts() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 300, "title": "Third"},
              {"startTime": 0, "title": "First"},
              {"startTime": 120.5, "title": "Second"}
            ]}
            """
        )

        #expect(chapters == [
            EpisodeChapter(id: 0, title: "First", startTime: 0),
            EpisodeChapter(id: 1, title: "Second", startTime: 120.5),
            EpisodeChapter(id: 2, title: "Third", startTime: 300)
        ])
    }

    @Test("Drops untitled, empty, whitespace-only and non-string titles; trims the rest")
    func dropsUnusableTitles() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 1},
              {"startTime": 2, "title": ""},
              {"startTime": 3, "title": "  \\n\\t "},
              {"startTime": 4, "title": null},
              {"startTime": 5, "title": 42},
              {"startTime": 6, "title": "  Padded \\n"},
              {"startTime": 7, "title": "Café — naïve 日本語"}
            ]}
            """
        )

        #expect(chapters == [
            EpisodeChapter(id: 0, title: "Padded", startTime: 6),
            EpisodeChapter(id: 1, title: "Café — naïve 日本語", startTime: 7)
        ])
    }

    @Test("Truncates over-long titles to 200 characters without splitting a character")
    func truncatesOverLongTitles() throws {
        let longTitle = String(repeating: "A", count: 150) + String(repeating: "🎙️", count: 100)
        let chapters = try decode(#"{"chapters":[{"startTime":0,"title":"\#(longTitle)"}]}"#)

        let title = try #require(chapters.first?.title)
        #expect(PublisherChaptersDocumentDecoder.maximumTitleLength == 200)
        #expect(title.count == 200)
        #expect(title == String(repeating: "A", count: 150) + String(repeating: "🎙️", count: 50))
    }

    @Test("A NaN start is not JSON")
    func nanStartIsInvalidJSON() {
        #expect(throws: PublisherChaptersDocumentError.invalidJSON) {
            try decode(#"{"chapters":[{"startTime":NaN,"title":"Not a number"}]}"#)
        }
    }

    @Test("Drops negative, string, bool, null, missing and overflowing starts")
    func dropsUnusableStarts() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": -1, "title": "Negative"},
              {"startTime": "12", "title": "String"},
              {"startTime": true, "title": "Bool"},
              {"startTime": null, "title": "Null"},
              {"title": "Missing"},
              {"startTime": 1e400, "title": "Overflow"},
              {"startTime": 12, "title": "Kept"}
            ]}
            """
        )

        #expect(chapters == [EpisodeChapter(id: 0, title: "Kept", startTime: 12)])
    }

    @Test("Drops starts past the timestamp bound and keeps those up to it")
    func dropsStartsPastTimestampBound() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 1e300, "title": "Astronomical"},
              {"startTime": 1e15, "title": "Geological"},
              {"startTime": 1000000001, "title": "Just past"},
              {"startTime": 1000000000, "title": "At the bound"},
              {"startTime": 999999999, "title": "Just under"},
              {"startTime": 12, "title": "Ordinary"}
            ]}
            """
        )

        #expect(PublisherChaptersDocumentDecoder.maximumTimestamp == 1_000_000_000)
        #expect(chapters == [
            EpisodeChapter(id: 0, title: "Ordinary", startTime: 12),
            EpisodeChapter(id: 1, title: "Just under", startTime: 999_999_999),
            EpisodeChapter(id: 2, title: "At the bound", startTime: 1_000_000_000)
        ])
    }

    @Test("Drops array elements that are not objects")
    func dropsNonObjectElements() throws {
        let chapters = try decode(#"{"chapters":[1,"x",null,true,[],[{"startTime":1,"title":"Nested"}],{"startTime":5,"title":"Kept"}]}"#)

        #expect(chapters == [EpisodeChapter(id: 0, title: "Kept", startTime: 5)])
    }

    @Test("Only a boolean false toc hides an entry")
    func onlyBooleanFalseTocHides() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 1, "title": "Hidden", "toc": false},
              {"startTime": 2, "title": "Listed", "toc": true},
              {"startTime": 3, "title": "String toc", "toc": "false"},
              {"startTime": 4, "title": "Null toc", "toc": null}
            ]}
            """
        )

        #expect(chapters.map(\.title) == ["Listed", "String toc", "Null toc"])
    }

    @Test("On duplicate starts the earliest kept entry in document order wins")
    func duplicateStartsKeepFirst() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 0, "title": "Boost", "toc": false},
              {"startTime": 0, "title": ""},
              {"startTime": 60, "title": "First at sixty"},
              {"startTime": 0, "title": "Opening"},
              {"startTime": 60, "title": "Second at sixty"},
              {"startTime": 0, "title": "Second opening"}
            ]}
            """
        )

        #expect(chapters == [
            EpisodeChapter(id: 0, title: "Opening", startTime: 0),
            EpisodeChapter(id: 1, title: "First at sixty", startTime: 60)
        ])
    }

    @Test("Keeps endTime only when it is a finite number after the start")
    func keepsOnlyUsableEndTimes() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 10, "endTime": 10, "title": "Equal"},
              {"startTime": 20, "endTime": 5, "title": "Earlier"},
              {"startTime": 30, "endTime": "40", "title": "String"},
              {"startTime": 40, "endTime": 1e400, "title": "Overflow"},
              {"startTime": 50, "endTime": null, "title": "Null"},
              {"startTime": 60, "endTime": 75.5, "title": "Later"}
            ]}
            """
        )

        #expect(chapters.map(\.title) == ["Equal", "Earlier", "String", "Overflow", "Null", "Later"])
        #expect(chapters.map(\.endTime) == [nil, nil, nil, nil, nil, 75.5])
    }

    @Test("An endTime past the timestamp bound reads as nil")
    func endTimePastTimestampBoundIsNil() throws {
        let chapters = try decode(
            """
            {"chapters": [
              {"startTime": 10, "endTime": 1e300, "title": "Astronomical"},
              {"startTime": 20, "endTime": 1e15, "title": "Geological"},
              {"startTime": 30, "endTime": 1000000001, "title": "Just past"},
              {"startTime": 40, "endTime": 1000000000, "title": "At the bound"}
            ]}
            """
        )

        #expect(chapters.map(\.title) == ["Astronomical", "Geological", "Just past", "At the bound"])
        #expect(chapters.map(\.endTime) == [nil, nil, nil, 1_000_000_000])
    }

    @Test("Roots that are not objects are malformed", arguments: ["[]", #""x""#, "42", "null", "true"])
    func nonObjectRootIsMalformed(json: String) {
        #expect(throws: PublisherChaptersDocumentError.malformedRoot) {
            try decode(json)
        }
    }

    @Test(
        "A missing or wrong-type chapters value is malformed",
        arguments: [
            "{}",
            #"{"version":"1.2.0"}"#,
            #"{"chapters":null}"#,
            #"{"chapters":{}}"#,
            #"{"chapters":"none"}"#,
            #"{"chapters":7}"#,
            #"{"Chapters":[]}"#
        ]
    )
    func missingOrWrongTypeChaptersIsMalformed(json: String) {
        #expect(throws: PublisherChaptersDocumentError.malformedRoot) {
            try decode(json)
        }
    }

    @Test("Bytes that are not JSON are invalid", arguments: ["", "{", #"{"chapters": ["#, "not json", "<rss/>"])
    func nonJSONIsInvalid(text: String) {
        #expect(throws: PublisherChaptersDocumentError.invalidJSON) {
            try decode(text)
        }
    }

    @Test("Empty chapters decode to no rows")
    func emptyChaptersDecodeToNothing() throws {
        #expect(try decode(#"{"version":"1.2.0","chapters":[]}"#).isEmpty)
    }

    @Test("A UTF-8 byte order mark is accepted")
    func acceptsByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"chapters":[{"startTime":0,"title":"Intro"}]}"#.utf8)

        let chapters = try PublisherChaptersDocumentDecoder.decode(data)

        #expect(chapters == [EpisodeChapter(id: 0, title: "Intro", startTime: 0)])
    }

    @Test("Nested junk under unknown keys is ignored")
    func ignoresNestedJunk() throws {
        let depth = 200
        let junk = String(repeating: #"{"a":["#, count: depth) + String(repeating: "]}", count: depth)
        let chapters = try decode(#"{"junk":\#(junk),"chapters":[{"startTime":1,"title":"Survivor","extra":\#(junk)}]}"#)

        #expect(chapters == [EpisodeChapter(id: 0, title: "Survivor", startTime: 1)])
    }

    @Test("Nesting past the parser's depth limit throws instead of trapping")
    func pathologicalNestingThrows() {
        let depth = 100_000
        let json = #"{"chapters":["# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "]}"

        #expect(throws: PublisherChaptersDocumentError.invalidJSON) {
            try decode(json)
        }
    }

    @Test("A 10,000-entry document keeps the earliest 1,000 chapters in start order")
    func capsAtOneThousandChapters() throws {
        let entries = (0..<10_000).reversed().map { #"{"startTime":\#($0),"title":"Chapter \#($0)"}"# }
        let chapters = try decode(#"{"version":"1.2.0","chapters":[\#(entries.joined(separator: ","))]}"#)

        #expect(PublisherChaptersDocumentDecoder.maximumChapterCount == 1_000)
        #expect(chapters.count == 1_000)
        #expect(chapters.map(\.id) == Array(0..<1_000))
        #expect(chapters.map(\.startTime) == (0..<1_000).map(Double.init))
        #expect(chapters.first?.title == "Chapter 0")
        #expect(chapters.last?.title == "Chapter 999")
    }

    @Test("A document over 2 MiB decodes without trapping")
    func decodesDocumentOverTwoMebibytes() throws {
        let longTitle = String(repeating: "Ä", count: 300)
        let entries = (0..<4_000).map { index in
            #"{"startTime":\#(Double(index) * 1.25),"title":"\#(longTitle)","img":"https://example.com/art/\#(index).png","url":"https://example.com/\#(index)"}"#
        }
        let data = Data(#"{"version":"1.2.0","chapters":[\#(entries.joined(separator: ","))]}"#.utf8)
        #expect(data.count > 2 * 1_024 * 1_024)

        let chapters = try PublisherChaptersDocumentDecoder.decode(data)

        #expect(chapters.count == 1_000)
        #expect(chapters.allSatisfy { $0.title.count == 200 })
        #expect(chapters.last?.startTime == 999 * 1.25)
    }

    @Test(
        "Real published documents decode to the observed chapters",
        arguments: [
            (PublisherChaptersFixtures.podcasting20Ep277, 38, "x402 Bitch! — Welcome to the Boardroom", "Strip Out the Ads — Close"),
            (PublisherChaptersFixtures.noAgendaEp1916, 52, "The Final Edition: Closing Time From Leo LaPuke", "The Last Voice"),
            (PublisherChaptersFixtures.changelogEp689, 26, "Welcome to The Changelog", "Closing thoughts and stuff"),
            (
                PublisherChaptersFixtures.buildYourSaaSEp163,
                10,
                "What did Helen do before she joined Transistor?",
                "How do future generations learn how to be on a team?"
            ),
            (PublisherChaptersFixtures.buzzcastEp253, 13, "Podcast Discovery Meets the Radio Dial", "Post Show: Ghost Tours"),
            (PublisherChaptersFixtures.podcastInsiderEp484, 0, nil, nil),
            (
                PublisherChaptersFixtures.audacityToPodcastEp452,
                9,
                "Introduction",
                "7. Share multiple things in each chapter with chapter resource pages"
            ),
            (PublisherChaptersFixtures.hrCoffeeTimeEp188, 21, "Introduction: Hidden Strengths", "Wrap Up")
        ] as [(PublisherChaptersFixture, Int, String?, String?)]
    )
    func decodesPublishedDocument(
        fixture: PublisherChaptersFixture,
        count: Int,
        firstTitle: String?,
        lastTitle: String?
    ) throws {
        let chapters = try PublisherChaptersDocumentDecoder.decode(fixture.data())

        #expect(chapters.count == count)
        #expect(chapters.first?.title == firstTitle)
        #expect(chapters.last?.title == lastTitle)
        #expect(chapters.map(\.id) == Array(chapters.indices))
    }

    @Test("Hidden boost entries in real documents never become rows or displace a chapter")
    func realHiddenEntriesStayHidden() throws {
        let noAgenda = try PublisherChaptersDocumentDecoder.decode(PublisherChaptersFixtures.noAgendaEp1916.data())
        let podcasting20 = try PublisherChaptersDocumentDecoder.decode(PublisherChaptersFixtures.podcasting20Ep277.data())

        #expect(noAgenda.first == EpisodeChapter(id: 0, title: "The Final Edition: Closing Time From Leo LaPuke", startTime: 0))
        #expect(noAgenda.prefix(2).map(\.startTime) == [0, 106.7])
        #expect(!(noAgenda + podcasting20).contains { $0.title.contains("sats from") })
        #expect((noAgenda + podcasting20).allSatisfy { $0.endTime == nil })
    }

    @Test("Real endTimes survive decoding")
    func realEndTimesSurvive() throws {
        let transistor = try PublisherChaptersDocumentDecoder.decode(PublisherChaptersFixtures.buildYourSaaSEp163.data())
        let changelog = try PublisherChaptersDocumentDecoder.decode(PublisherChaptersFixtures.changelogEp689.data())
        let captivate = try PublisherChaptersDocumentDecoder.decode(PublisherChaptersFixtures.hrCoffeeTimeEp188.data())

        #expect(transistor.first == EpisodeChapter(
            id: 0,
            title: "What did Helen do before she joined Transistor?",
            startTime: 133.56,
            endTime: 180.78
        ))
        #expect(changelog.allSatisfy { $0.endTime != nil })
        #expect(changelog.last?.endTime == 8_822)
        #expect(captivate.last?.endTime == 2_743.066)
    }

    private func decode(_ json: String) throws -> [EpisodeChapter] {
        try PublisherChaptersDocumentDecoder.decode(Data(json.utf8))
    }
}
