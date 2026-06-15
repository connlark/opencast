import Foundation
import OpenCastCore
import Testing

@Suite("OPML exporting")
struct OPMLExporterTests {
    @Test("Exports valid OPML 2.0")
    func exportsValidOPML2() throws {
        let data = try OPMLExporter().export(
            feedReferences: [
                OPMLFeedReference(
                    title: "Example Show",
                    feedURL: URL(string: "https://example.com/feed.xml")!
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let xml = String(decoding: data, as: UTF8.self)

        #expect(xml.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
        #expect(xml.contains(#"<opml version="2.0">"#))
        #expect(xml.contains("<title>opencast Subscriptions</title>"))
        #expect(xml.contains("<dateCreated>1970-01-01T00:00:00Z</dateCreated>"))
    }

    @Test("Includes RSS outline attributes")
    func includesRSSOutlineAttributes() throws {
        let data = try OPMLExporter().export(
            feedReferences: [
                OPMLFeedReference(
                    title: "Example Show",
                    feedURL: URL(string: "https://example.com/feed.xml")!,
                    htmlURL: URL(string: "https://example.com/show")
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let xml = String(decoding: data, as: UTF8.self)

        #expect(xml.contains(#"<outline type="rss" text="Example Show" title="Example Show" xmlUrl="https://example.com/feed.xml" htmlUrl="https://example.com/show" />"#))
    }

    @Test("Escapes special XML characters")
    func escapesSpecialXMLCharacters() throws {
        let data = try OPMLExporter().export(
            feedReferences: [
                OPMLFeedReference(
                    title: #"A & <B> "C" 'D'"#,
                    feedURL: URL(string: "https://example.com/feed.xml?b=2&a=1")!
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let xml = String(decoding: data, as: UTF8.self)

        #expect(xml.contains(#"text="A &amp; &lt;B&gt; &quot;C&quot; &apos;D&apos;""#))
        #expect(xml.contains(#"xmlUrl="https://example.com/feed.xml?a=1&amp;b=2""#))
    }

    @Test("Round-trips through parser")
    func roundTripsThroughParser() throws {
        let references = [
            OPMLFeedReference(
                title: "One",
                feedURL: URL(string: "https://example.com/one.xml")!
            ),
            OPMLFeedReference(
                title: "Two",
                feedURL: URL(string: "https://example.com/two.xml")!
            )
        ]
        let data = try OPMLExporter().export(
            feedReferences: references,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let parsedReferences = try OPMLParser().parse(data: data)

        #expect(parsedReferences == references)
    }

    @Test("Produces deterministic output when generatedAt is fixed")
    func producesDeterministicOutput() throws {
        let reference = OPMLFeedReference(
            title: "Example Show",
            feedURL: URL(string: "https://example.com/feed.xml")!
        )
        let generatedAt = Date(timeIntervalSince1970: 0)

        let first = try OPMLExporter().export(feedReferences: [reference], generatedAt: generatedAt)
        let second = try OPMLExporter().export(feedReferences: [reference], generatedAt: generatedAt)

        #expect(first == second)
    }
}
