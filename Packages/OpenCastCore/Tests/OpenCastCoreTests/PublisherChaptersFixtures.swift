import Foundation
import Testing

enum PublisherChaptersFixtures {
    static let podcasting20Ep277 = PublisherChaptersFixture(
        resource: "publisher-chapters-podcasting20-ep277",
        feedURL: "https://feeds.podcastindex.org/pc20.xml",
        episodeTitle: #"Episode 277: "x402 Bitch!""#,
        documentURL: "https://reflex.livewire.io/chapters/podcast/917393e3-1b1e-5cef-ace4-edaa54e1f810/item/PC20-277/chapters/https://mp3s.nashownotes.com/PC20-277-Chapters.json",
        fetchedAt: "2026-11-13T03:18:28Z",
        hostingPlatform: "Sovereign Feeds, document served through the LiveWire reflex proxy",
        notes: """
        Em-dash titles, url keys, one toc:false boost entry carrying endTime and img, root author, \
        title, podcastName and fileName keys. The declared URL embeds the origin URL in its path. \
        Served as application/json with cache-control private, no-cache.
        """
    )

    static let noAgendaEp1916 = PublisherChaptersFixture(
        resource: "publisher-chapters-noagenda-ep1916",
        feedURL: "https://feeds.noagendaassets.com/noagenda.xml",
        episodeTitle: #"1916 "The Final Episode""#,
        documentURL: "https://reflex.livewire.io/chapters/podcast/856cd618-7f34-57ea-9b84-3600f1f65e7f/item/http://1916.noagendanotes.com/chapters/https://mp3s.nashownotes.com/NA-1916-Chapters.json",
        fetchedAt: "2026-11-13T03:18:26Z",
        hostingPlatform: "Sovereign Feeds, document served through the LiveWire reflex proxy",
        notes: """
        The longest list found (61 entries over 5.8 hours): img on every entry, fractional starts, and \
        nine toc:false boost entries with endTime, the first of which shares start 0 with the real first \
        chapter and precedes it. Feed fetched from http://feed.nashownotes.com/rss.xml, which redirects \
        to the feedURL. Served as application/json with cache-control private, no-cache.
        """
    )

    static let changelogEp689 = PublisherChaptersFixture(
        resource: "publisher-chapters-changelog-ep689",
        feedURL: "https://changelog.com/podcast/feed",
        episodeTitle: "We now have Kerr’s Law (Interview)",
        documentURL: "https://changelog.com/podcast/689/chapters",
        fetchedAt: "2026-11-13T03:18:25Z",
        hostingPlatform: "changelog.com (self-hosted)",
        notes: """
        endTime on every entry, an unknown number key, url on sponsor entries, curly-apostrophe \
        titles, minified. Served as application/json with cache-control no-store.
        """
    )

    static let buildYourSaaSEp163 = PublisherChaptersFixture(
        resource: "publisher-chapters-buildyoursaas-ep163",
        feedURL: "https://feeds.transistor.fm/build-your-saas",
        episodeTitle: "What is Transistor's secret weapon?",
        documentURL: "https://share.transistor.fm/s/9c22a01c/chapters.json",
        fetchedAt: "2026-11-13T03:19:23Z",
        hostingPlatform: "Transistor",
        notes: """
        Fractional starts with endTime on every entry; the first chapter starts at 133.56 s, not 0. \
        Pretty-printed. Served as application/json+chapters.
        """
    )

    static let buzzcastEp253 = PublisherChaptersFixture(
        resource: "publisher-chapters-buzzcast-ep253",
        feedURL: "https://rss.buzzsprout.com/231452.rss",
        episodeTitle: "Can AI Find Your Podcast? A Real-World AEO Test",
        documentURL: "https://www.buzzsprout.com/231452/20079447/chapters.json",
        fetchedAt: "2026-11-13T03:18:25Z",
        hostingPlatform: "Buzzsprout",
        notes: """
        Version 1.1.0, startTime and title only, whole-second starts written as floats (0.0). Feed \
        fetched from https://feeds.buzzsprout.com/231452.rss, which redirects to the feedURL. Served \
        as application/json.
        """
    )

    static let podcastInsiderEp484 = PublisherChaptersFixture(
        resource: "publisher-chapters-podcastinsider-ep484",
        feedURL: "https://feeds.blubrry.com/feeds/podcastinsider.xml",
        episodeTitle: "How Long Should a Podcast Episode Be? And Should You Edit? – PCI 484",
        documentURL: "https://transcripts.blubrry.com/podcastinsider/chapters/1789423671.json",
        fetchedAt: "2026-11-13T03:19:23Z",
        hostingPlatform: "Blubrry",
        notes: """
        A placeholder the feed still declares: one entry at 0 with a null title, so it decodes to no \
        chapters. Served as application/json+chapters from S3.
        """
    )

    static let audacityToPodcastEp452 = PublisherChaptersFixture(
        resource: "publisher-chapters-audacitytopodcast-ep452",
        feedURL: "https://feeds.podcastmirror.com/theaudacitytopodcast",
        episodeTitle: "452. Why You Should Use PodChapters to Chapter and Transcribe Your Podcast",
        documentURL: "https://storage.podchapters.com/j973bkwgxk3jpd4j3mw02g6b717p8s52/tap452/metadata.json",
        fetchedAt: "2026-11-13T03:20:10Z",
        hostingPlatform: "PodChapters document host, WordPress + PowerPress feed",
        notes: """
        Version "1.2" (not three-part), a root description, millisecond-precision starts, img and url \
        keys, and a toc:false entry that repeats an earlier listed chapter's title. Served as \
        application/json.
        """
    )

    static let hrCoffeeTimeEp188 = PublisherChaptersFixture(
        resource: "publisher-chapters-hrcoffeetime-ep188",
        feedURL: "https://feeds.captivate.fm/hr-coffee-time/",
        episodeTitle: "188 | “That’s Not Special, That’s Just Me”: How to Spot the Strengths You Can’t See (with Michele Deeks & Martin Galpin)",
        documentURL: "https://transcripts.captivate.fm/chapter-0ef84ee0-7a25-4bf1-8df4-633104edff6d.json",
        fetchedAt: "2026-11-13T03:20:10Z",
        hostingPlatform: "Captivate",
        notes: """
        endTime on every entry, integer starts, a fractional final endTime. The feed declares \
        application/json+chapters; the host serves application/json.
        """
    )
}
