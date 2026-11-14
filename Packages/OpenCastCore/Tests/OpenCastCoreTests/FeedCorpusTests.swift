import Foundation
import OpenCastCore
import Testing

@Suite("Feed corpus")
struct FeedCorpusTests {
    /// What `RSSFeedParser` returns for each file; `Corpus/PROVENANCE.md` counts its `<item` elements.
    private static let episodeCounts: [String: Int] = [
        "audacitytopodcast": 452,
        "backupwrapup": 370,
        "buildyoursaas": 163,
        "businesswithoutbs": 403,
        "buzzcast": 268,
        "cheekypint": 42,
        "corehappiness": 74,
        "dwarkeshpodcast": 145,
        "hrcoffeetime": 191,
        "investlikethebest": 606,
        "nopriors": 188,
        "podcasting20": 210,
        "podcastinsider": 524,
        "pragmaticengineer": 82
    ]

    @Test("Each feed loads and parses whole into its pinned episode count", arguments: FeedCorpus.all)
    func parsesWhole(feed: FeedCorpus) throws {
        let pinned = try #require(Self.episodeCounts[feed.resource], "\(feed.resource) has no pinned episode count")
        #expect(try !feed.data().isEmpty)
        let snapshot = try feed.snapshot()
        #expect(!snapshot.isSalvaged)
        #expect(snapshot.episodes.count == pinned)
    }

    @Test("Every feed file in the bundle has a FeedCorpus static, and every static has a file")
    func directoryAndListAgree() throws {
        let directory = try #require(Bundle.module.resourceURL).appending(path: "Corpus/feeds", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" }
            .map { $0.deletingPathExtension().lastPathComponent }
        let resources = FeedCorpus.all.map(\.resource)

        #expect(Set(resources).count == resources.count)
        #expect(Set(files) == Set(resources))
    }

    @Test(
        "Named episodes resolve by exact title and by GUID, and their show notes carry the first timestamp line",
        arguments: [
            (FeedCorpus.investLikeTheBest, #"Zach Reitano - Building Ro and Why Healthcare Should Be 50% of GDP - [Invest Like the Best, EP.500]"#, #"f2c43732-dd18-11f1-bff2-0bf5984a7473"#, #"(00:01:35) Why Healthcare Spending Should Rise"#, true),
            (FeedCorpus.investLikeTheBest, #"David George - Building a16z Growth, Investing Across the AI Stack, and Why Markets Misprice Growth - [Invest Like the Best, EP.450]"#, #"8da7dbd8-ceeb-11f0-941c-ef83bcdd4c9f"#, #"(00:00:00) Welcome to Invest Like The Best"#, true),
            (FeedCorpus.investLikeTheBest, #"Sam Hinkie – Find Your People - [Invest Like the Best, EP.204]"#, #"ad15d146-f49a-476d-8af5-aa1b7205cc20"#, #"(3:48) – (First question) – Conducting a good interview"#, true),
            (FeedCorpus.noPriors, #"Powering AI-Driven Drug Discovery with President of Isomorphic Labs Max Jaderberg"#, #"c9a0c39e-de2a-11f1-9237-d39059052d4c"#, #"00:00 – Trailer"#, true),
            (FeedCorpus.noPriors, #"Andrej Karpathy on Code Agents, AutoResearch, and the Loopy Era of AI"#, #"e12140a6-245e-11f1-83d8-d393763beb3b"#, #"00:00 Andrej Karpathy Introduction"#, true),
            (FeedCorpus.backupWrapUp, #"Application Whitelisting Best Practices: The Silver Bullet Nobody Uses"#, #"e733fd40-85c9-4c8d-9424-8374a08ca7ef"#, #"00:00:00 – Intro"#, true),
            (FeedCorpus.backupWrapUp, #"Cybersecurity Best Practices for Individuals (Encore)"#, #"95adcf36-c70b-4161-bb6a-e0a80687b614"#, #"00:00 Cold open"#, true),
            (FeedCorpus.backupWrapUp, #"How Polymorphic Malware Evades Detection — And What to Do About It"#, #"0dc454ed-a970-4910-95d9-843127c1c9c5"#, #"00:00:00 – Intro"#, true),
            (FeedCorpus.pragmaticEngineer, #"Why Rust is different, with Alice Ryhl"#, #"substack:post:198284678"#, #"(00:00) Intro"#, true),
            (FeedCorpus.pragmaticEngineer, #"Python, Go, Rust, TypeScript and AI with Armin Ronacher"#, #"substack:post:175461206"#, #"• (06:53) How Python, Go, and Rust stack up and when to use each one"#, true),
            (FeedCorpus.pragmaticEngineer, #"Building Reddit’s iOS and Android app"#, #"substack:post:161916016"#, #"(00:00) Intro"#, true),
            (FeedCorpus.cheekyPint, #"Elon Musk on Space GPUs, AI, Optimus, and his manufacturing method"#, #"7bef465c-4808-43af-9ca6-dca975ae8997"#, #"00:00:23 Space GPUs"#, true),
            (FeedCorpus.dwarkeshPodcast, #"Thoughts on AI progress (Dec 2025)"#, #"substack:post:182443852"#, #"00:00:00 What are we scaling?"#, true),
            (FeedCorpus.dwarkeshPodcast, #"A billion years of evolution in a single afternoon — George Church"#, #"substack:post:166888604"#, #"(0:00:00) – Aging solved by 2050"#, true),
            (FeedCorpus.dwarkeshPodcast, #"Uncle Bob - The Long Reach of Code"#, #"e4203d6a-12bf-488a-a3e8-8d9385395c20"#, #"(0:00) - Automating programming"#, true),
            (FeedCorpus.coreHappiness, #"From Toxic Patterns to True Self-Worth with Kamini Wood"#, #"4c166f7d-344b-47cc-858e-510d3c07a509"#, #"00:00 Introduction to Setting Boundaries"#, true),
            (FeedCorpus.coreHappiness, #"Understanding Emotional Backlash: Navigating Guilt and Self-Trust After Setting Boundaries"#, #"2210dc23-2e10-413b-9410-c4ebfb11c2db"#, #"00:00 — Introduction: Setting Boundaries and Self-Reflection"#, true),
            (FeedCorpus.businessWithoutBS, #"When A Business Goes Bust: What Happens Next? | Carrie James"#, #"flightcast:01M5FBFTXFQT3CS8N2M81RXZHA"#, #"00:00 Cold open"#, true),
            (FeedCorpus.businessWithoutBS, #"Why most UK marketing fails without data, with Simon Leadbetter, former Knight Frank CMO"#, #"90b8b64b-fcfa-405e-9532-15b03196608f"#, #"0:00 Customers don’t care about you"#, true),
            (FeedCorpus.businessWithoutBS, #"BWB Live at the Cannabis Farm"#, #"8524a05f-4fec-4015-8164-6d99d0f008db"#, #"00:00 BWB Live at Glass Pharms"#, true),
            (FeedCorpus.hrCoffeeTime, #"188 | “That’s Not Special, That’s Just Me”: How to Spot the Strengths You Can’t See (with Michele Deeks & Martin Galpin)"#, #"10f38ce2-a6c1-4673-891d-4c987dbc7c17"#, #"[00:00] Introduction: Hidden Strengths"#, true),
            (FeedCorpus.hrCoffeeTime, #"056 | How to do a great job with collective consultations for redundancies, with Pete Colby"#, #"0f2168fe-14ea-4373-9575-df6813b32d48"#, #"[01:25] An introduction to Pete Colby"#, true),
            (FeedCorpus.buildYourSaaS, #"What is Transistor's secret weapon?"#, #"b34e7e5b-750f-43e1-ab2e-3cc93f7fb5fd"#, #"(02:13) - What did Helen do before she joined Transistor?"#, true),
            (FeedCorpus.buildYourSaaS, #"What's it really like to work at Transistor?"#, #"78198668-a48c-4ae4-be51-62ecf1e45476"#, #"0:55 Jason's first podcast ever"#, true),
            (FeedCorpus.buildYourSaaS, #"Why should we care about our customers' feelings?"#, #"0eec7005-06a4-4857-b4c8-02bbf4c21e14"#, #"31:30 – we start discussing customer interviews"#, true),
            (FeedCorpus.buzzcast, #"We Listened To Your Podcasts And Gave Actionable Feedback"#, #"Buzzsprout-18382925"#, #"7:20 Wander Worldschool"#, false),
            (FeedCorpus.buzzcast, #"Spotify Launches Open Access Monetization + Dynamic Content 2.0"#, #"Buzzsprout-8944744"#, #"12:00pm - New Podcast Primer"#, false),
            (FeedCorpus.audacityToPodcast, #"452. Why You Should Use PodChapters to Chapter and Transcribe Your Podcast"#, nil, #"Introduction [00:00]"#, true),
            (FeedCorpus.podcasting20, #"Episode 272: "Is this Y'all?""#, #"PC20-272"#, ##"12:10 &mdash; "#api &lt;b&gt;Adding 2 new indexes on the feeds table.&lt;/b&gt;"##, true),
            (FeedCorpus.podcasting20, #"Episode 274: "Vibe Cloning""#, #"PC20-274"#, #"the show is &lt;b&gt;10:08&lt;/b&gt; (2:56&ndash;13:04)"#, true),
            (FeedCorpus.podcastInsider, #"Jeremy Bassetti from All Over The Place Podcast – PI-151"#, nil, #"Mike: 11:30 on Wednesday, Podcast Distribution. on the solutions stage."#, true),
        ] as [(FeedCorpus, String, String?, String, Bool)]
    )
    func namedEpisodes(
        feed: FeedCorpus,
        title: String,
        guid: String?,
        firstTimestampLine: String,
        summaryCarriesList: Bool
    ) throws {
        let byTitle = try feed.episode(titled: title)
        // A GUID that is a URL stays out of Swift (feed hosts live in PROVENANCE.md only), so
        // that episode resolves by the GUID its title match carries.
        let pinnedGUID = try guid ?? #require(byTitle.guid)
        #expect(byTitle.guid == pinnedGUID)
        #expect(try feed.episode(guid: pinnedGUID).id == byTitle.id)

        #expect(Self.text(of: byTitle.showNotesHTML).contains(firstTimestampLine))
        #expect(Self.text(of: byTitle.summary).contains(firstTimestampLine) == summaryCarriesList)
    }

    @Test("episode(titled:) fails on a title the feed does not have")
    func absentTitleFails() {
        withKnownIssue {
            _ = try FeedCorpus.cheekyPint.episode(titled: "An episode this feed never published")
        }
    }

    /// The field with its markup removed and its entities left as written, which is how the
    /// pinned lines were copied out of the raw descriptions.
    private static func text(of field: String?) -> String {
        (field ?? "").replacing(/<[^>]+>/, with: "")
    }
}
