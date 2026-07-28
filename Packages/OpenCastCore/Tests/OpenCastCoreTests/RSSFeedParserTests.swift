import Foundation
import OpenCastCore
import Testing

@Suite("RSS feed parsing")
struct RSSFeedParserTests {
    @Test("Parses RSS and iTunes namespace fields from the synthetic fixture")
    func parsesFixture() throws {
        let snapshot = try fixtureSnapshot()

        #expect(snapshot.podcast.title == "Example Current Affairs")
        #expect(snapshot.podcast.author == "Example Studios")
        #expect(snapshot.podcast.id.rawValue == "https://feeds.example.com/example-current-affairs.xml")
        #expect(snapshot.podcast.artworkURL?.absoluteString == "https://example.com/example-current-affairs.jpg")
        #expect(snapshot.episodes.count == 2)
        #expect(snapshot.episodes[0].title == "Episode With GUID")
        #expect(snapshot.episodes[0].duration == 3_723)
        #expect(snapshot.episodes[0].showNotesHTML?.contains("Full notes") == true)
    }

    @Test("Parses enclosure audio URLs")
    func parsesAudioURLs() throws {
        let snapshot = try fixtureSnapshot()

        #expect(snapshot.episodes[0].audioURL?.absoluteString == "https://example.com/audio/example-001.mp3")
        #expect(snapshot.episodes[1].audioURL?.absoluteString == "https://example.com/audio/example-002.mp3")
    }

    @Test("Nested image and text-input metadata does not overwrite channel fields")
    func nestedMetadataDoesNotOverwriteChannelFields() throws {
        let snapshot = try fixtureSnapshot(
            named: "image-block",
            feedURL: URL(string: "https://example.com/image-block.xml")!
        )

        #expect(snapshot.podcast.title == "Primary Podcast Title")
        #expect(snapshot.podcast.websiteURL?.absoluteString == "https://example.com/podcast")
        #expect(snapshot.podcast.artworkURL?.absoluteString == "https://example.com/artwork.jpg")
    }

    @Test("Recovers common, unknown, and bare HTML entities")
    func recoversHTMLEntities() throws {
        let snapshot = try fixtureSnapshot(
            named: "entity-recovery",
            feedURL: URL(string: "https://example.com/entity-recovery.xml")!
        )

        #expect(snapshot.episodes.count == 2)
        #expect(snapshot.episodes[0].title == "Before Recovery")
        #expect(snapshot.episodes[0].summary == "Rock & Roll keeps &future; literal.")
        #expect(snapshot.episodes[1].title == "Space Oddity & Beyond &future; — More…")
    }

    @Test("Recovers entities using the XML-prolog encoding")
    func recoversEntitiesUsingDeclaredEncoding() throws {
        let xml = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <rss version="2.0">
          <channel>
            <title>Café&nbsp;Sessions</title>
            <item>
              <title>Crème</title>
              <guid>latin-one</guid>
              <enclosure url="https://example.com/latin-one.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let data = try #require(xml.data(using: .isoLatin1))
        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/latin-one.xml")!
        )

        #expect(snapshot.podcast.title == "Café Sessions")
        #expect(snapshot.episodes.first?.title == "Crème")
    }

    @Test("Selects the first usable enclosure unless later audio is better")
    func selectsAudioEnclosures() throws {
        let snapshot = try fixtureSnapshot(
            named: "enclosures",
            feedURL: URL(string: "https://example.com/enclosures.xml")!
        )

        #expect(snapshot.episodes[0].audioURL?.absoluteString == "https://example.com/first.mp3")
        #expect(snapshot.episodes[1].audioURL?.absoluteString == "https://example.com/second.mp3")
        #expect(snapshot.episodes[2].audioURL?.absoluteString == "https://example.com/third.mp3")
    }

    @Test("Accumulates text across unescaped inline elements")
    func accumulatesTextAcrossUnescapedInlineElements() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Open <em>Cast</em> Weekly</title>
                <description>Show <strong>summary</strong> text</description>
                <item>
                  <title>Season <em>2</em> Finale</title>
                  <guid>mixed-content</guid>
                  <description>Hello <b>bold</b> and <i>italic</i> world</description>
                  <enclosure url="https://example.com/mixed.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let feedURL = try #require(URL(string: "https://example.com/mixed.xml"))
        let snapshot = try RSSFeedParser().parse(data: data, feedURL: feedURL)
        let episode = try #require(snapshot.episodes.first)

        #expect(snapshot.podcast.title == "Open Cast Weekly")
        #expect(snapshot.podcast.summary == "Show summary text")
        #expect(episode.title == "Season 2 Finale")
        #expect(episode.summary == "Hello bold and italic world")
        #expect(episode.showNotesHTML == "Hello bold and italic world")
    }

    @Test("Parses PDT item pubDate values")
    func parsesPDTItemPubDateValues() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Security Now</title>
                <item>
                  <title>Named Zone Episode</title>
                  <guid>named-zone-episode</guid>
                  <pubDate>Tue, 30 Jun 2026 18:43:36 PDT</pubDate>
                  <enclosure url="https://example.com/security-now.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/sn.xml")!)

        #expect(snapshot.episodes.first?.publishedAt?.timeIntervalSince1970 == 1_782_870_216)
    }

    @Test("Parses fallback identity inputs when GUID and duration are missing")
    func parsesFallbackIdentityInputs() throws {
        let feedURL = URL(string: "https://example.com/fallbacks.xml")!
        let snapshot = try fixtureSnapshot(named: "fallbacks", feedURL: feedURL)
        let audioEpisode = try #require(snapshot.episodes.first { $0.title == "Audio URL Stable Original" })
        let titleDateEpisode = try #require(snapshot.episodes.first { $0.title == "Title Date Stable" })

        #expect(audioEpisode.duration == nil)
        #expect(audioEpisode.guid == nil)
        #expect(audioEpisode.audioURL?.absoluteString == "https://example.com/audio/stable-audio.mp3")
        #expect(
            audioEpisode.id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: nil,
                audioURL: audioEpisode.audioURL,
                title: "Audio URL Stable Retitled",
                publishedAt: audioEpisode.publishedAt
            )
        )

        #expect(titleDateEpisode.duration == nil)
        #expect(titleDateEpisode.guid == nil)
        #expect(titleDateEpisode.audioURL == nil)
        #expect(
            titleDateEpisode.id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: nil,
                audioURL: nil,
                title: "Title Date Stable",
                publishedAt: titleDateEpisode.publishedAt
            )
        )
    }

    @Test("Rejects feeds with no episodes")
    func rejectsFeedsWithNoEpisodes() throws {
        let url = try #require(Bundle.module.url(forResource: "empty", withExtension: "xml"))
        let data = try Data(contentsOf: url)

        #expect(throws: OpenCastCoreError.self) {
            try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/empty.xml")!)
        }
    }

    @Test(
        "Parses channel language values",
        arguments: [
            ("de-DE", "de-DE"),
            ("en-us", "en-us"),
            ("fr", "fr"),
            (" pt-BR ", "pt-BR"),
            ("zh_Hans", "zh_Hans"),
            ("Deutsch (Germany)", nil),
            ("", nil),
            ("x", nil),
            ("en-", nil)
        ] as [(String, String?)]
    )
    func parsesChannelLanguage(rawValue: String, expected: String?) throws {
        let snapshot = try RSSFeedParser().parse(
            data: languageFeedData(languageElement: "<language>\(rawValue)</language>"),
            feedURL: URL(string: "https://example.com/lang.xml")!
        )

        #expect(snapshot.podcast.languageCode == expected)
    }

    @Test("Missing channel language parses as nil")
    func missingChannelLanguageParsesAsNil() throws {
        let fixture = try fixtureSnapshot()
        #expect(fixture.podcast.languageCode == nil)

        let inline = try RSSFeedParser().parse(
            data: languageFeedData(languageElement: ""),
            feedURL: URL(string: "https://example.com/lang.xml")!
        )
        #expect(inline.podcast.languageCode == nil)
    }

    @Test("Item-level language does not overwrite channel language")
    func itemLanguageDoesNotOverwriteChannelLanguage() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Lang Feed</title>
                <language>de-DE</language>
                <item>
                  <title>One</title>
                  <guid>one</guid>
                  <language>fr</language>
                  <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/lang.xml")!)
        #expect(snapshot.podcast.languageCode == "de-DE")
    }
}

private func languageFeedData(languageElement: String) -> Data {
    Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Lang Feed</title>
            \(languageElement)
            <item>
              <title>One</title>
              <guid>one</guid>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
            </item>
          </channel>
        </rss>
        """.utf8
    )
}

private func fixtureSnapshot() throws -> FeedSnapshot {
    try fixtureSnapshot(
        named: "examplecurrentaffairs",
        feedURL: URL(string: "https://feeds.example.com/example-current-affairs.xml")!
    )
}

private func fixtureSnapshot(named name: String, feedURL: URL) throws -> FeedSnapshot {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml"))
    let data = try Data(contentsOf: url)
    return try RSSFeedParser().parse(data: data, feedURL: feedURL)
}
