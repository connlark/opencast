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

    @Test("Channel metadata stays intact alongside large show notes")
    func channelMetadataStaysIntactAlongsideLargeShowNotes() throws {
        let bigNotes = String(repeating: "Show note sentence. ", count: 2_000)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Contained Feed</title>
            <description>Channel summary</description>
            <link>https://example.com/contained</link>
            <item>
              <title>Big Notes <em>Episode</em></title>
              <guid>contained-1</guid>
              <description>Inline <b>bold</b> summary</description>
              <content:encoded>\(bigNotes)</content:encoded>
              <enclosure url="https://example.com/audio/contained-1.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """

        let snapshot = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/contained.xml")!
        )
        let episode = try #require(snapshot.episodes.first)

        #expect(snapshot.podcast.title == "Contained Feed")
        #expect(snapshot.podcast.summary == "Channel summary")
        #expect(snapshot.podcast.websiteURL?.absoluteString == "https://example.com/contained")
        #expect(episode.title == "Big Notes Episode")
        #expect(episode.summary == "Inline bold summary")
        #expect(episode.showNotesHTML?.hasPrefix("Show note sentence.") == true)
    }

    @Test("Parses the channel's itunes:new-feed-url declaration")
    func parsesNewFeedURLDeclaration() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Moving Show</title>
                <itunes:new-feed-url>https://example.net/moved.xml</itunes:new-feed-url>
                <item>
                  <title>One</title>
                  <guid>moving-1</guid>
                  <enclosure url="https://example.com/audio/moving-1.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/moving.xml")!
        )

        #expect(snapshot.newFeedURL?.absoluteString == "https://example.net/moved.xml")
    }

    @Test("Parses the channel's podcast:guid declaration")
    func parsesPodcastGUIDDeclaration() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Identified Show</title>
                <podcast:guid>2d7400e3-bacb-52fd-aabc-0da55e39f98b</podcast:guid>
                <item>
                  <title>One</title>
                  <guid>identified-1</guid>
                  <enclosure url="https://example.com/audio/identified-1.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/identified.xml")!
        )

        #expect(snapshot.podcast.podcastGUID == "2d7400e3-bacb-52fd-aabc-0da55e39f98b")
        #expect(snapshot.episodes.first?.guid == "identified-1")
    }

    @Test("Parses per-item podcast:chapters URLs and leaves others nil")
    func parsesPodcastChaptersURLs() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Chaptered Show</title>
                <item>
                  <title>With Chapters</title>
                  <guid>chaptered-1</guid>
                  <podcast:chapters url="https://example.com/chapters/1.json" type="application/json+chapters" />
                  <enclosure url="https://example.com/audio/chaptered-1.mp3" type="audio/mpeg" />
                </item>
                <item>
                  <title>Without Chapters</title>
                  <guid>chaptered-2</guid>
                  <enclosure url="https://example.com/audio/chaptered-2.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/chaptered.xml")!
        )

        #expect(snapshot.episodes.count == 2)
        #expect(snapshot.episodes[0].chaptersURL?.absoluteString == "https://example.com/chapters/1.json")
        #expect(snapshot.episodes[1].chaptersURL == nil)
    }

    @Test("Captures chapters declared under a non-canonical Podcast Index namespace prefix")
    func capturesChaptersUnderNonCanonicalNamespacePrefix() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:pc="https://podcastindex.org/namespace/1.0">
              <channel>
                <title>Renamed Prefix Show</title>
                <item>
                  <title>Root-Declared Prefix</title>
                  <guid>renamed-1</guid>
                  <pc:chapters url="https://example.com/chapters/renamed-1.json" type="application/json+chapters" />
                  <enclosure url="https://example.com/audio/renamed-1.mp3" type="audio/mpeg" />
                </item>
                <item>
                  <title>Element-Declared Prefix</title>
                  <guid>renamed-2</guid>
                  <ch:chapters xmlns:ch="https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md" url="https://example.com/chapters/renamed-2.json" />
                  <enclosure url="https://example.com/audio/renamed-2.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/renamed-prefix.xml")!
        )

        #expect(snapshot.episodes.count == 2)
        #expect(snapshot.episodes[0].chaptersURL?.absoluteString == "https://example.com/chapters/renamed-1.json")
        #expect(snapshot.episodes[1].chaptersURL?.absoluteString == "https://example.com/chapters/renamed-2.json")
    }

    @Test("Ignores chapters elements from prefixes bound to other namespaces")
    func ignoresChaptersFromForeignNamespacePrefixes() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:other="https://example.com/not-the-podcast-namespace">
              <channel>
                <title>Foreign Prefix Show</title>
                <item>
                  <title>Foreign Chapters</title>
                  <guid>foreign-1</guid>
                  <other:chapters url="https://example.com/chapters/foreign-1.json" />
                  <enclosure url="https://example.com/audio/foreign-1.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/foreign-prefix.xml")!
        )

        #expect(snapshot.episodes.count == 1)
        #expect(snapshot.episodes[0].chaptersURL == nil)
    }

    @Test("A prefix rebound to a foreign namespace stops matching within that scope")
    func reboundPrefixStopsMatchingWithinScope() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:pc="https://podcastindex.org/namespace/1.0">
              <channel>
                <title>Rebound Prefix Show</title>
                <item>
                  <title>Rebound On Item</title>
                  <guid>rebound-1</guid>
                  <pc:chapters xmlns:pc="https://example.com/not-the-podcast-namespace" url="https://example.com/chapters/rebound-1.json" />
                  <enclosure url="https://example.com/audio/rebound-1.mp3" type="audio/mpeg" />
                </item>
                <item>
                  <title>Canonical Prefix Rebound</title>
                  <guid>rebound-2</guid>
                  <podcast:chapters xmlns:podcast="https://example.com/not-the-podcast-namespace" url="https://example.com/chapters/rebound-2.json" />
                  <enclosure url="https://example.com/audio/rebound-2.mp3" type="audio/mpeg" />
                </item>
                <item>
                  <title>Outer Binding Restored</title>
                  <guid>rebound-3</guid>
                  <pc:chapters url="https://example.com/chapters/rebound-3.json" />
                  <enclosure url="https://example.com/audio/rebound-3.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/rebound-prefix.xml")!
        )

        #expect(snapshot.episodes.count == 3)
        #expect(snapshot.episodes[0].chaptersURL == nil)
        #expect(snapshot.episodes[1].chaptersURL == nil)
        #expect(snapshot.episodes[2].chaptersURL?.absoluteString == "https://example.com/chapters/rebound-3.json")
    }

    @Test("A podcast namespace binding does not outlive its element scope")
    func podcastNamespaceBindingDoesNotOutliveScope() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Scoped Binding Show</title>
                <item xmlns:sc="https://podcastindex.org/namespace/1.0">
                  <title>In Scope</title>
                  <guid>scoped-1</guid>
                  <sc:chapters url="https://example.com/chapters/scoped-1.json" />
                  <enclosure url="https://example.com/audio/scoped-1.mp3" type="audio/mpeg" />
                </item>
                <item>
                  <title>Out Of Scope</title>
                  <guid>scoped-2</guid>
                  <sc:chapters url="https://example.com/chapters/scoped-2.json" />
                  <enclosure url="https://example.com/audio/scoped-2.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/scoped-binding.xml")!
        )

        #expect(snapshot.episodes.count == 2)
        #expect(snapshot.episodes[0].chaptersURL?.absoluteString == "https://example.com/chapters/scoped-1.json")
        #expect(snapshot.episodes[1].chaptersURL == nil)
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

    @Test("Fixture episode IDs stay stable across date-parser changes")
    func fixtureEpisodeIDsStayStable() throws {
        let feedURL = try #require(URL(string: "https://example.com/fallbacks.xml"))
        let snapshot = try fixtureSnapshot(named: "fallbacks", feedURL: feedURL)
        let audioEpisode = try #require(snapshot.episodes.first { $0.title == "Audio URL Stable Original" })
        let titleDateEpisode = try #require(snapshot.episodes.first { $0.title == "Title Date Stable" })

        #expect(audioEpisode.publishedAt?.timeIntervalSince1970 == 1_775_649_600)
        #expect(titleDateEpisode.publishedAt?.timeIntervalSince1970 == 1_775_736_000)
        #expect(
            titleDateEpisode.id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: nil,
                audioURL: nil,
                title: "Title Date Stable",
                publishedAt: Date(timeIntervalSince1970: 1_775_736_000)
            )
        )
    }

    @Test("Returns an empty snapshot for feeds without episodes")
    func returnsEmptySnapshotForFeedsWithoutEpisodes() throws {
        let url = try #require(Bundle.module.url(forResource: "empty", withExtension: "xml"))
        let data = try Data(contentsOf: url)

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/empty.xml")!
        )

        #expect(snapshot.podcast.title == "Empty Show")
        #expect(snapshot.episodes.isEmpty)
    }

    @Test("Reports Atom documents as not a feed")
    func reportsAtomDocumentsAsNotAFeed() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Atom Show</title>
              <entry>
                <title>Atom Entry</title>
                <id>urn:uuid:atom-entry-1</id>
              </entry>
            </feed>
            """.utf8
        )

        #expect(throws: OpenCastCoreError.notAFeed(rootElement: "feed")) {
            try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/atom.xml")!)
        }
    }

    @Test("Reports HTML documents as not a feed")
    func reportsHTMLDocumentsAsNotAFeed() throws {
        let data = Data(
            """
            <!DOCTYPE html>
            <html>
            <head><title>A Web Page</title>
            <body>
            <p>Not a feed
            </body>
            </html>
            """.utf8
        )

        #expect(throws: OpenCastCoreError.notAFeed(rootElement: "html")) {
            try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/page")!)
        }
    }

    @Test("Non-UTF-8 CDATA falls back to the prolog-declared encoding")
    func nonUTF8CDATAFallsBackToDeclaredEncoding() throws {
        let latinXML = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <rss version="2.0">
          <channel>
            <title>Latin Show</title>
            <item>
              <title>Latin Episode</title>
              <guid>latin-cdata</guid>
              <description><![CDATA[Café crème notes]]></description>
              <enclosure url="https://example.com/latin.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let data = try #require(latinXML.data(using: .isoLatin1))

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/latin-cdata.xml")!
        )

        #expect(snapshot.episodes.first?.summary == "Café crème notes")
    }

    @Test("Double-encoded entities in titles decode at parse time")
    func doubleEncodedTitleEntitiesDecodeAtParseTime() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Rock &amp;amp; Roll Hour</title>
                <itunes:author>Smith &amp;amp; Jones</itunes:author>
                <item>
                  <title>Fish &amp;amp;amp; Chips &amp;#8212; Live</title>
                  <guid>double-encoded</guid>
                  <enclosure url="https://example.com/audio/double.mp3" type="audio/mpeg" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let snapshot = try RSSFeedParser().parse(
            data: data,
            feedURL: URL(string: "https://example.com/double.xml")!
        )

        #expect(snapshot.podcast.title == "Rock & Roll Hour")
        #expect(snapshot.podcast.author == "Smith & Jones")
        #expect(snapshot.episodes.first?.title == "Fish & Chips — Live")
    }

    @Test("Repeated GUIDs with distinct enclosures materialize distinct episodes")
    func repeatedGUIDsWithDistinctEnclosuresMaterializeDistinctEpisodes() throws {
        let feedURL = try #require(URL(string: "https://example.com/repeated-guid.xml"))
        let items = (1...3).map { index in
            """
            <item>
              <title>Collider \(index)</title>
              <guid>shared-guid</guid>
              <pubDate>Tue, 0\(index) Jun 2026 10:00:00 GMT</pubDate>
              <enclosure url="https://example.com/audio/collider-\(index).mp3" type="audio/mpeg" />
            </item>
            """
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Repeated GUID Feed</title>
            \(items)
          </channel>
        </rss>
        """

        let snapshot = try RSSFeedParser().parse(data: Data(xml.utf8), feedURL: feedURL)

        #expect(snapshot.episodes.count == 3)
        #expect(Set(snapshot.episodes.map(\.id)).count == 3)
        #expect(
            snapshot.episodes[0].id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: "shared-guid",
                audioURL: snapshot.episodes[0].audioURL,
                title: "Collider 1",
                publishedAt: snapshot.episodes[0].publishedAt
            )
        )
        #expect(
            snapshot.episodes[1].id == EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: nil,
                audioURL: URL(string: "https://example.com/audio/collider-2.mp3"),
                title: "Collider 2",
                publishedAt: snapshot.episodes[1].publishedAt
            )
        )
    }

    @Test("Truly identical repeated items still collapse")
    func trulyIdenticalRepeatedItemsStillCollapse() throws {
        let item = """
        <item>
          <title>Doubled Episode</title>
          <guid>doubled</guid>
          <pubDate>Tue, 02 Jun 2026 10:00:00 GMT</pubDate>
          <enclosure url="https://example.com/audio/doubled.mp3" type="audio/mpeg" />
        </item>
        """
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Doubled Feed</title>
            \(item)
            \(item)
          </channel>
        </rss>
        """

        let snapshot = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/doubled.xml")!
        )

        #expect(snapshot.episodes.map(\.title) == ["Doubled Episode"])
    }

    @Test("Salvages fully-parsed episodes from a truncated feed")
    func salvagesFullyParsedEpisodesFromTruncatedFeed() throws {
        let items = (1...3).map { index in
            """
            <item>
              <title>Episode \(index)</title>
              <guid>truncated-\(index)</guid>
              <enclosure url="https://example.com/audio/truncated-\(index).mp3" type="audio/mpeg" />
            </item>
            """
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Truncated Show</title>
            \(items)
            <item>
              <title>Torn Episo
        """

        let snapshot = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/truncated.xml")!
        )

        #expect(snapshot.isSalvaged)
        #expect(snapshot.podcast.title == "Truncated Show")
        #expect(snapshot.episodes.map(\.title) == ["Episode 1", "Episode 2", "Episode 3"])
    }

    @Test("Aborts and salvages when nesting exceeds the depth budget")
    func abortsAndSalvagesWhenNestingExceedsDepthBudget() throws {
        let nesting = (0..<60).map { "<nest\($0)>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Deep Feed</title>
            <item>
              <title>Complete Episode</title>
              <guid>deep-1</guid>
              <enclosure url="https://example.com/audio/deep-1.mp3" type="audio/mpeg" />
            </item>
            \(nesting)
          </channel>
        </rss>
        """

        let snapshot = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/deep.xml")!
        )

        #expect(snapshot.isSalvaged)
        #expect(snapshot.episodes.map(\.title) == ["Complete Episode"])
    }

    @Test("Aborts and salvages when a single text node exceeds the budget")
    func abortsAndSalvagesWhenTextNodeExceedsBudget() throws {
        let hugeText = String(repeating: "a", count: 13 * 1_024 * 1_024)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Huge Text Feed</title>
            <item>
              <title>Complete Episode</title>
              <guid>huge-1</guid>
              <enclosure url="https://example.com/audio/huge-1.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Oversized Episode</title>
              <guid>huge-2</guid>
              <description>\(hugeText)</description>
            </item>
          </channel>
        </rss>
        """

        let snapshot = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/huge.xml")!
        )

        #expect(snapshot.isSalvaged)
        #expect(snapshot.episodes.map(\.title) == ["Complete Episode"])
    }

    @Test("Caps the number of parsed items")
    func capsTheNumberOfParsedItems() throws {
        let items = (1...10_002).map { index in
            "<item><title>E\(index)</title><guid>cap-\(index)</guid></item>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Capped Feed</title>
            \(items)
          </channel>
        </rss>
        """

        let snapshot = try RSSFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/capped.xml")!
        )

        #expect(snapshot.isSalvaged)
        #expect(snapshot.episodes.count == 10_000)
    }

    @Test("Reports malformed XML as a malformed feed")
    func reportsMalformedXMLAsMalformedFeed() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0">
              <channel>
                <title>Broken Feed</title>
            """.utf8
        )

        do {
            _ = try RSSFeedParser().parse(data: data, feedURL: URL(string: "https://example.com/broken.xml")!)
            Issue.record("Expected malformed XML to throw")
        } catch let error as OpenCastCoreError {
            guard case .malformedFeed = error else {
                Issue.record("Expected malformedFeed, got \(error)")
                return
            }
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
