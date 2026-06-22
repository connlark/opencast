import Foundation
import OpenCastCore
import Testing

@Suite("OPML parsing")
struct OPMLParserTests {
    @Test("Parses simple RSS outlines")
    func parsesSimpleRSSOutlines() throws {
        let result = try OPMLParser().parseResult(data: fixtureData(named: "subscriptions-simple"))

        #expect(result.feedReferences.map(\.title) == ["Alpha & Beta", "Beta Show"])
        #expect(result.feedReferences.map(\.canonicalFeedURL) == [
            "https://example.com/alpha.xml",
            "https://example.com/beta.xml"
        ])
        #expect(result.feedReferences.first?.htmlURL?.absoluteString == "https://example.com/alpha")
        #expect(result.usableFeedReferenceCount == 2)
        #expect(result.duplicateFeedReferenceCount == 0)
    }

    @Test("Parses HTTP podcast feeds from imported subscription lists")
    func parsesHTTPPodcastFeedsFromImportedSubscriptionLists() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <body>
                <outline type="rss" text="War Nerd Radio \u{2014} Subscriber Feed" xmlUrl="http://exiledonline.com/45wn84klrz/feed.xml" />
                <outline type="rss" text="The Seed Podcast" xmlUrl="http://seed.example.com/" />
              </body>
            </opml>
            """.utf8
        )

        let references = try OPMLParser().parse(data: data)

        #expect(references.map(\.title) == ["War Nerd Radio \u{2014} Subscriber Feed", "The Seed Podcast"])
        #expect(references.map(\.canonicalFeedURL) == [
            "http://exiledonline.com/45wn84klrz/feed.xml",
            "http://seed.example.com"
        ])
    }

    @Test("Parses nested folder outlines")
    func parsesNestedFolderOutlines() throws {
        let references = try OPMLParser().parse(data: fixtureData(named: "subscriptions-nested"))

        #expect(references.map(\.title) == ["Nested Show", "Caps URL Show", "Non RSS Type"])
        #expect(references.map(\.canonicalFeedURL) == [
            "https://example.com/nested.xml",
            "https://example.com/caps.xml",
            "https://example.com/non-rss-type.xml"
        ])
    }

    @Test("Accepts missing or non-RSS type when xmlUrl is present")
    func acceptsMissingOrNonRSSType() throws {
        let references = try OPMLParser().parse(data: fixtureData(named: "subscriptions-nested"))

        #expect(references.contains { $0.title == "Nested Show" })
        #expect(references.contains { $0.title == "Non RSS Type" })
    }

    @Test("Uses text attribute when title is missing")
    func usesTextAttributeWhenTitleIsMissing() throws {
        let references = try OPMLParser().parse(data: fixtureData(named: "subscriptions-text-only"))

        #expect(references.first?.title == "Text Only Show")
    }

    @Test("Prefers text attribute over title")
    func prefersTextAttributeOverTitle() throws {
        let references = try OPMLParser().parse(data: fixtureData(named: "subscriptions-text-title-precedence"))

        #expect(references.first?.title == "Display Show")
    }

    @Test("Ignores outlines without valid feed URLs")
    func ignoresInvalidFeedURLs() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <body>
                <outline text="Missing URL" />
                <outline text="FTP" xmlUrl="ftp://example.com/feed.xml" />
                <outline text="Relative" xmlUrl="/feeds/show.xml" />
                <outline text="Valid" xmlUrl="https://example.com/valid.xml" />
              </body>
            </opml>
            """.utf8
        )

        let references = try OPMLParser().parse(data: data)

        #expect(references.map(\.canonicalFeedURL) == ["https://example.com/valid.xml"])
    }

    @Test("De-dupes canonical equivalents")
    func dedupesCanonicalEquivalents() throws {
        let result = try OPMLParser().parseResult(data: fixtureData(named: "subscriptions-duplicates"))

        #expect(result.feedReferences.map(\.title) == ["First Query Show", "Trailing Slash Show"])
        #expect(result.feedReferences.map(\.canonicalFeedURL) == [
            "https://example.com/feed.xml?a=1&b=2",
            "https://example.com/trailing.xml"
        ])
        #expect(result.usableFeedReferenceCount == 4)
        #expect(result.duplicateFeedReferenceCount == 2)
    }

    @Test("Preserves first occurrence order")
    func preservesFirstOccurrenceOrder() throws {
        let references = try OPMLParser().parse(data: fixtureData(named: "subscriptions-simple"))

        #expect(references.map(\.canonicalFeedURL) == [
            "https://example.com/alpha.xml",
            "https://example.com/beta.xml"
        ])
    }

    @Test("Decodes XML-escaped attribute values")
    func decodesEscapedAttributeValues() throws {
        let references = try OPMLParser().parse(data: fixtureData(named: "subscriptions-special-characters"))
        let reference = try #require(references.first)

        #expect(reference.title == #"Fun & <Special> "Quotes" 'Apostrophes'"#)
        #expect(reference.canonicalFeedURL == "https://example.com/feed.xml?name=fun&tag=a%26b")
    }

    @Test("Throws for malformed XML")
    func throwsForMalformedXML() throws {
        #expect(throws: OPMLError.malformedDocument) {
            try OPMLParser().parse(data: fixtureData(named: "subscriptions-malformed"))
        }
    }

    @Test("Throws for no usable subscriptions")
    func throwsForNoUsableSubscriptions() throws {
        #expect(throws: OPMLError.emptySubscriptionList) {
            try OPMLParser().parse(data: fixtureData(named: "subscriptions-empty"))
        }
    }
}

private func fixtureData(named name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "opml"))
    return try Data(contentsOf: url)
}
