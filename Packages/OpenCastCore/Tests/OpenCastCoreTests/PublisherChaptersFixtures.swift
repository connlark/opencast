import Foundation
import Testing

enum PublisherChaptersFixtures {
    static let podcasting20Ep277 = PublisherChaptersFixture(
        resource: "podcasting20-ep277",
        episodeTitle: #"Episode 277: "x402 Bitch!""#,
        fetchedAt: "2026-11-13T03:18:28Z",
        hostingPlatform: "Sovereign Feeds, document served through the LiveWire reflex proxy",
        notes: """
        Em-dash titles, url keys, one toc:false boost entry carrying endTime and img, root author, \
        title, podcastName and fileName keys. The declared URL embeds the origin URL in its path. \
        Served as application/json with cache-control private, no-cache.
        """
    )

    static let noAgendaEp1916 = PublisherChaptersFixture(
        resource: "noagenda-ep1916",
        episodeTitle: #"1916 "The Final Episode""#,
        fetchedAt: "2026-11-13T03:18:26Z",
        hostingPlatform: "Sovereign Feeds, document served through the LiveWire reflex proxy",
        notes: """
        The longest list found (61 entries over 5.8 hours): img on every entry, fractional starts, and \
        nine toc:false boost entries with endTime, the first of which shares start 0 with the real first \
        chapter and precedes it. Feed fetched through a redirect from the show's older feed URL \
        (PROVENANCE.md). Served as application/json with cache-control private, no-cache.
        """
    )

    static let changelogEp689 = PublisherChaptersFixture(
        resource: "changelog-ep689",
        episodeTitle: "We now have Kerr’s Law (Interview)",
        fetchedAt: "2026-11-13T03:18:25Z",
        hostingPlatform: "changelog.com (self-hosted)",
        notes: """
        endTime on every entry, an unknown number key, url on sponsor entries, curly-apostrophe \
        titles, minified. Served as application/json with cache-control no-store.
        """
    )

    static let buildYourSaaSEp163 = PublisherChaptersFixture(
        resource: "buildyoursaas-ep163",
        episodeTitle: "What is Transistor's secret weapon?",
        fetchedAt: "2026-11-13T03:19:23Z",
        hostingPlatform: "Transistor",
        notes: """
        Fractional starts with endTime on every entry; the first chapter starts at 133.56 s, not 0. \
        Pretty-printed. Served as application/json+chapters.
        """
    )

    static let buzzcastEp253 = PublisherChaptersFixture(
        resource: "buzzcast-ep253",
        episodeTitle: "Can AI Find Your Podcast? A Real-World AEO Test",
        fetchedAt: "2026-11-13T03:18:25Z",
        hostingPlatform: "Buzzsprout",
        notes: """
        Version 1.1.0, startTime and title only, whole-second starts written as floats (0.0). Feed \
        fetched through a redirect from the show's older feed URL (PROVENANCE.md). Served as \
        application/json.
        """
    )

    static let podcastInsiderEp484 = PublisherChaptersFixture(
        resource: "podcastinsider-ep484",
        episodeTitle: "How Long Should a Podcast Episode Be? And Should You Edit? – PCI 484",
        fetchedAt: "2026-11-13T03:19:23Z",
        hostingPlatform: "Blubrry",
        notes: """
        A placeholder the feed still declares: one entry at 0 with a null title, so it decodes to no \
        chapters. Served as application/json+chapters from S3.
        """
    )

    static let audacityToPodcastEp452 = PublisherChaptersFixture(
        resource: "audacitytopodcast-ep452",
        episodeTitle: "452. Why You Should Use PodChapters to Chapter and Transcribe Your Podcast",
        fetchedAt: "2026-11-13T03:20:10Z",
        hostingPlatform: "PodChapters document host, WordPress + PowerPress feed",
        notes: """
        Version "1.2" (not three-part), a root description, millisecond-precision starts, img and url \
        keys, and a toc:false entry that repeats an earlier listed chapter's title. Served as \
        application/json.
        """
    )

    static let hrCoffeeTimeEp188 = PublisherChaptersFixture(
        resource: "hrcoffeetime-ep188",
        episodeTitle: "188 | “That’s Not Special, That’s Just Me”: How to Spot the Strengths You Can’t See (with Michele Deeks & Martin Galpin)",
        fetchedAt: "2026-11-13T03:20:10Z",
        hostingPlatform: "Captivate",
        notes: """
        endTime on every entry, integer starts, a fractional final endTime. The feed declares \
        application/json+chapters; the host serves application/json.
        """
    )
}
