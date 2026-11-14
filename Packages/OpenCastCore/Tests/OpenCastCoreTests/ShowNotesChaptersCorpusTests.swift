import Foundation
import OpenCastCore
import Testing

/// Real descriptions through the production pipeline: the feed parser's `showNotesHTML`, `structuredText`, then the
/// chapters parser with the episode's own duration. Expected values are read off the raw description lines.
@Suite("Show-notes chapters in the feed corpus")
struct ShowNotesChaptersCorpusTests {
    @Test("Invest Like the Best EP.500: all 13 entries under its Timestamps heading, from 95 s across the hour")
    func investLikeTheBestEP500() throws {
        let chapters = try chapters(FeedCorpus.investLikeTheBest, guid: "f2c43732-dd18-11f1-bff2-0bf5984a7473")

        #expect(chapters.map(\.startTime) == [95, 339, 637, 989, 1_395, 1_715, 2_193, 2_629, 2_787, 3_247, 3_615, 3_879, 4_374])
        #expect(chapters.map(\.title) == [
            "Why Healthcare Spending Should Rise",
            "Putting Patients in Control",
            "Inside Ro's GLP-1 Business",
            "How GLP-1s Could Reshape Society",
            "The Hidden Cost of Protecting Jobs",
            "Rebuilding a Zombie Company",
            "What Drove Ro's 10x Growth",
            "Where Healthcare Goes Next",
            "Zach's Personal Health Stack",
            "Finding the Work You Were Born For",
            "Ro's Consumer Playbook",
            "Breaking Medical Taboos",
            "The Kindest Thing"
        ])
        #expect(chapters.map(\.id) == Array(0..<13))
    }

    @Test(
        "A real list reads whole: the count a person reads, and its first and last entries",
        arguments: [
            (FeedCorpus.investLikeTheBest, "ad15d146-f49a-476d-8af5-aa1b7205cc20", 35, 228, "(First question) – Conducting a good interview", 4_378, "The power of breadcrumbs and how people can start to lay them out"),
            (FeedCorpus.noPriors, "e12140a6-245e-11f1-83d8-d393763beb3b", 13, 0, "Andrej Karpathy Introduction", 3_940, "Conclusion"),
            (FeedCorpus.backupWrapUp, "e733fd40-85c9-4c8d-9424-8374a08ca7ef", 23, 0, "Intro", 2_601, "Final thoughts"),
            (FeedCorpus.backupWrapUp, "0dc454ed-a970-4910-95d9-843127c1c9c5", 12, 0, "Intro", 1_617, "Risk-based defense: protect what matters most"),
            (FeedCorpus.pragmaticEngineer, "substack:post:198284678", 19, 0, "Intro", 3_834, "Book recommendation"),
            (FeedCorpus.cheekyPint, "7bef465c-4808-43af-9ca6-dca975ae8997", 8, 23, "Space GPUs", 9_298, "Space GPUs redux"),
            (FeedCorpus.dwarkeshPodcast, "substack:post:166888604", 11, 0, "Aging solved by 2050", 5_126, "How one lab spawned 100 biotech companies"),
            (FeedCorpus.dwarkeshPodcast, "e4203d6a-12bf-488a-a3e8-8d9385395c20", 9, 0, "Automating programming", 2_549, "Advice to 20 yr old"),
            (FeedCorpus.coreHappiness, "4c166f7d-344b-47cc-858e-510d3c07a509", 14, 0, "Introduction to Setting Boundaries", 2_633, "Final Thoughts and Resources"),
            (FeedCorpus.coreHappiness, "2210dc23-2e10-413b-9410-c4ebfb11c2db", 9, 0, "Introduction: Setting Boundaries and Self-Reflection", 486, "Conclusion: Embracing the Discomfort of Becoming"),
            (FeedCorpus.businessWithoutBS, "flightcast:01M5FBFTXFQT3CS8N2M81RXZHA", 17, 0, "Cold open", 4_744, "Business or Hocus Pocus?"),
            (FeedCorpus.hrCoffeeTime, "10f38ce2-a6c1-4673-891d-4c987dbc7c17", 21, 0, "Introduction: Hidden Strengths", 2_626, "Wrap Up"),
            (FeedCorpus.buildYourSaaS, "b34e7e5b-750f-43e1-ab2e-3cc93f7fb5fd", 10, 133, "What did Helen do before she joined Transistor?", 2_021, "How do future generations learn how to be on a team?"),
            (FeedCorpus.buzzcast, "Buzzsprout-18382925", 6, 440, "Wander Worldschool", 2_913, "This Is How You Think")
        ] as [(FeedCorpus, String, Int, TimeInterval, String, TimeInterval, String)]
    )
    func wholeLists(
        feed: FeedCorpus,
        guid: String,
        count: Int,
        firstStart: TimeInterval,
        firstTitle: String,
        lastStart: TimeInterval,
        lastTitle: String
    ) throws {
        let chapters = try chapters(feed, guid: guid)

        #expect(chapters.count == count)
        #expect(chapters.first?.startTime == firstStart)
        #expect(chapters.first?.title == firstTitle)
        #expect(chapters.last?.startTime == lastStart)
        #expect(chapters.last?.title == lastTitle)
    }

    @Test("An opening bracket without its closing one still leads an entry: EP.204's (7:49 – line is chapter 3")
    func unclosedBracket() throws {
        let chapters = try chapters(FeedCorpus.investLikeTheBest, guid: "ad15d146-f49a-476d-8af5-aa1b7205cc20")

        #expect(chapters.count == 35)
        #expect(chapters.dropFirst(2).first?.startTime == 469)
        #expect(chapters.dropFirst(2).first?.title == "What percentage of people are actually worth spending time with for Sam")
    }

    @Test("A three-line highlights run loses to the 16-entry list after it: Armin Ronacher")
    func highlightsRunLoses() throws {
        let chapters = try chapters(FeedCorpus.pragmaticEngineer, guid: "substack:post:175461206")

        #expect(chapters.count == 16)
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.first?.title == "Intro")
        #expect(chapters.last?.startTime == 4_299)
        #expect(chapters.last?.title == "Rapid fire round")
    }

    @Test("An out-of-order entry is dropped, not split on: David George keeps 21 of 22, losing the too-large (00:04:00)")
    func outOfOrderSecondEntry() throws {
        let chapters = try chapters(FeedCorpus.investLikeTheBest, guid: "8da7dbd8-ceeb-11f0-941c-ef83bcdd4c9f")

        #expect(chapters.count == 21)
        #expect(chapters.prefix(2).map(\.startTime) == [0, 184])
        #expect(chapters.prefix(2).map(\.title) == ["Welcome to Invest Like The Best", "Understanding the Impact of AI on Consumers and Enterprises"])
        #expect(chapters.last?.startTime == 3_824)
        #expect(chapters.last?.title == "The Kindest Thing")
        #expect(!chapters.contains { $0.title == "Meet David George" })
    }

    @Test("An out-of-order entry is dropped, not split on: Reddit keeps 25 of 26, losing the larger of (32:08) and (30:55)")
    func outOfOrderMiddleEntry() throws {
        let chapters = try chapters(FeedCorpus.pragmaticEngineer, guid: "substack:post:161916016")

        #expect(chapters.count == 25)
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.first?.title == "Intro")
        #expect(chapters.last?.startTime == 4_830)
        #expect(chapters.last?.title == "Rapid fire round")
        #expect(chapters.contains { $0.startTime == 1_855 && $0.title == "The impact of migrating from Rust to GraphQL" })
        #expect(!chapters.contains { $0.title == "The new design system" })
    }

    @Test("A too-large typo is dropped and the entries after it survive: John Collison keeps 25 of 26, losing (50:58)")
    func tooLargeTypoInList() throws {
        let chapters = try chapters(FeedCorpus.investLikeTheBest, guid: "1e35dbb5-353b-4d7e-ac87-24e38a18ae1a")

        #expect(chapters.count == 25)
        #expect(chapters.first?.startTime == 90)
        #expect(chapters.first?.title == "(First question) – Interest in industrial conglomerates")
        #expect(chapters.last?.startTime == 4_729)
        #expect(chapters.last?.title == "Advice for young people")
        #expect(!chapters.contains { $0.title == "Allowing teams to explore new ideas at Stripe" })
    }

    @Test("A typo'd 00:00 in the middle of a list is dropped: BWB Gender Bias keeps 19 of 20, the opening four included")
    func midListZeroTypo() throws {
        let chapters = try chapters(FeedCorpus.businessWithoutBS, guid: "77a8fe80-1a27-4f09-b9a2-fcda95e64410")

        #expect(chapters.count == 19)
        #expect(chapters.prefix(5).map(\.startTime) == [0, 94, 163, 316, 764])
        #expect(chapters.prefix(5).map(\.title) == [
            "BWB with Rachel Watkyn OBE",
            "Meet Rachel: A Journey of Resilience",
            "Quickfire - Get to Know Rachel",
            "Rachel's New Venture: Tackling Loneliness",
            "Personal Stories and Overcoming Adversity"
        ])
        #expect(chapters.last?.startTime == 3_529)
        #expect(chapters.last?.title == "Wrap Up")
        #expect(!chapters.contains { $0.title == "The Reality of Loneliness in Modern Society" })
    }

    @Test("A prose line ends a block: HR Coffee Time 056's disclosure paragraph splits 13 into 10 and 3")
    func disclosureSplitsList() throws {
        let chapters = try chapters(FeedCorpus.hrCoffeeTime, guid: "0f2168fe-14ea-4373-9575-df6813b32d48")

        #expect(chapters.count == 10)
        #expect(chapters.first?.startTime == 85)
        #expect(chapters.first?.title == "An introduction to Pete Colby")
        #expect(chapters.last?.startTime == 1_588)
        #expect(chapters.last?.title == "Pete shares his book recommendation - Getting to Yes: Negotiating an Agreement Without Giving In by Roger Fisher and William URY")
    }

    @Test("A prose line ends a block: a nested sub-bullet splits work-at-Transistor into 3 and 11 (11 of 14)")
    func subBulletSplitsList() throws {
        let chapters = try chapters(FeedCorpus.buildYourSaaS, guid: "78198668-a48c-4ae4-be51-62ecf1e45476")

        #expect(chapters.count == 11)
        #expect(chapters.first?.startTime == 812)
        #expect(chapters.first?.title == #"The best features the ones that feel like "magic" when a customer uses them"#)
        #expect(chapters.last?.startTime == 2_536)
        #expect(chapters.last?.title == "Patreon shout outs")
    }

    @Test("The duration drops entries past it: BWB Live at the Cannabis Farm keeps 11 of 19")
    func entriesPastDuration() throws {
        let episode = try FeedCorpus.businessWithoutBS.episode(guid: "8524a05f-4fec-4015-8164-6d99d0f008db")
        let chapters = Self.chapters(in: episode.showNotesHTML, duration: episode.duration)

        #expect(episode.duration == 1_691)
        #expect(chapters.count == 11)
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.first?.title == "BWB Live at Glass Pharms")
        #expect(chapters.last?.startTime == 1_686)
        #expect(chapters.last?.title == "Cannabis and Chronic Pain")
        #expect(Self.chapters(in: episode.showNotesHTML, duration: nil).count == 19)
    }

    @Test("The duration drops entries past it: No Priors' Conclusion starts one second past the duration (16 of 17)")
    func lastEntryOneSecondPastDuration() throws {
        let episode = try FeedCorpus.noPriors.episode(guid: "c9a0c39e-de2a-11f1-9237-d39059052d4c")
        let chapters = Self.chapters(in: episode.showNotesHTML, duration: episode.duration)

        #expect(episode.duration == 2_355)
        #expect(chapters.count == 16)
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.first?.title == "Trailer")
        #expect(chapters.last?.startTime == 2_142)
        #expect(chapters.last?.title == "Human Longevity and Drug Development")
        #expect(Self.chapters(in: episode.showNotesHTML, duration: nil).last?.startTime == 2_356)
    }

    @Test("An entry exactly at the duration is kept: No Priors' CrowdStrike Conclusion starts at the file's last second (20 of 20)")
    func lastEntryExactlyAtDuration() throws {
        let episode = try FeedCorpus.noPriors.episode(guid: "c69c028a-cdc7-11f1-a97a-77799e86d8ea")
        let chapters = Self.chapters(in: episode.showNotesHTML, duration: episode.duration)

        #expect(episode.duration == 2_727)
        #expect(chapters.count == 20)
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.first?.title == "Trailer")
        #expect(chapters.last?.startTime == 2_727)
        #expect(chapters.last?.title == "Conclusion")
    }

    @Test("One entry per line: Dwarkesh writes two entries on one line, so six topics give five chapters")
    func twoEntriesOnOneLine() throws {
        let chapters = try chapters(FeedCorpus.dwarkeshPodcast, guid: "substack:post:182443852")

        #expect(chapters.map(\.startTime) == [0, 191, 304, 503, 558])
        #expect(chapters.map(\.title) == [
            "What are we scaling?",
            "The value of human labor",
            "Economic diffusion lag is cope00:06:34 Goal-post shifting is justified",
            "RL scaling",
            "Broadly deployed intelligence explosion"
        ])
    }

    @Test("Known misread: minutes written as 00:MM read as seconds, so the Encore list lands in its first 45 seconds")
    func minutesWrittenAsSeconds() throws {
        let chapters = try chapters(FeedCorpus.backupWrapUp, guid: "95adcf36-c70b-4161-bb6a-e0a80687b614")

        #expect(chapters.map(\.startTime) == [0, 3, 10, 15, 16, 19, 23, 24, 25, 26, 28, 31, 34, 35, 43, 45])
        #expect(chapters.first?.title == "Cold open")
        #expect(chapters.dropFirst(11).first?.title == "Careful what you post online")
        #expect(chapters.last?.title == "Just do something — the summary that named the episode")
        #expect(!chapters.contains { $0.title == "Company-level MFA and security best practices" })
    }

    @Test("Escaped markup in the show notes yields nothing, while the plain-text summary yields the list")
    func escapedShowNotesPlainSummary() throws {
        let episode = try FeedCorpus.businessWithoutBS.episode(guid: "90b8b64b-fcfa-405e-9532-15b03196608f")

        #expect(HTMLPlainText.structuredText(from: episode.showNotesHTML ?? "").contains("<p>0:00 Customers"))
        #expect(Self.chapters(in: episode.showNotesHTML, duration: episode.duration).isEmpty)

        let summary = Self.chapters(in: episode.summary, duration: episode.duration)
        #expect(summary.count == 14)
        #expect(summary.first?.startTime == 0)
        #expect(summary.first?.title == "Customers don’t care about you")
        #expect(summary.last?.startTime == 3_720)
        #expect(summary.last?.title == "The one thing to do this week")
    }

    @Test(
        "Timestamps that are not a chapter list yield nothing",
        arguments: [
            (FeedCorpus.buzzcast, "Buzzsprout-8944744"),
            (FeedCorpus.buildYourSaaS, "0eec7005-06a4-4857-b4c8-02bbf4c21e14")
        ] as [(FeedCorpus, String)]
    )
    func notChapterLists(feed: FeedCorpus, guid: String) throws {
        #expect(try chapters(feed, guid: guid).isEmpty)
    }

    @Test("Title-first lines are not entries: The Audacity to Podcast 452 yields nothing")
    func titleFirstLines() throws {
        // Its GUID is a URL, and feed hosts stay out of Swift.
        let episode = try FeedCorpus.audacityToPodcast.episode(titled: "452. Why You Should Use PodChapters to Chapter and Transcribe Your Podcast")

        #expect(HTMLPlainText.structuredText(from: episode.showNotesHTML ?? "").contains("Introduction [00:00]"))
        #expect(Self.chapters(in: episode.showNotesHTML, duration: episode.duration).isEmpty)
    }

    @Test("A run D1 accepts that is not a chapter list: Podcasting 2.0 episode 272's 24-hour post times, two on its last line")
    func clockTimeRunIsNotAChapterList() throws {
        let episode = try FeedCorpus.podcasting20.episode(guid: "PC20-272")
        let lines = HTMLPlainText.structuredText(from: episode.showNotesHTML ?? "").split(whereSeparator: \.isNewline).map(String.init)
        // Quoted posts and the times they went up on one day, as `structuredText` gives the lines: the feed escapes its
        // markup, so `<b>` is text, and `&middot;` joins a fifth post (20:03) onto the fourth line.
        let entries: [(time: String, start: TimeInterval, title: String)] = [
            ("12:10", 730, ##""#api <b>Adding 2 new indexes on the feeds table.</b> Expect the api to choke for a few minutes until this completes.""##),
            ("14:38", 878, ##""#api <b>All out brawl with the feed aggregators this morning. I'm about to win though.</b>""##),
            ("17:08", 1_028, ##""<b>Battle is over. The war is ongoing.</b>""##),
            ("20:02", 1_202, ##""#api I fixed a huge problem with the feed aggregators. Based on this snapshot of our database metrics, <b>can you guess at roughly what time that happened?</b>" &middot; 20:03 — "<b>Network throughput up. CPU and disk rate down. It's a win-win.</b>""##)
        ]
        for entry in entries {
            #expect(lines.contains("\(entry.time) — \(entry.title)"))
        }

        let chapters = Self.chapters(in: episode.showNotesHTML, duration: episode.duration)
        #expect(chapters.map(\.startTime) == entries.map(\.start))
        // Titles are capped as a chapters document's are, which cuts the fourth line inside its second post.
        #expect(chapters.map(\.title) == entries.map { String($0.title.prefix(PublisherChaptersDocumentDecoder.maximumTitleLength)) })
        // The app shows the chapters document the episode declares instead.
        #expect(episode.chaptersURL != nil)
    }

    @Test("Timestamps scattered through prose yield nothing: Podcasting 2.0 episode 274")
    func timestampsScatteredThroughProse() throws {
        let episode = try FeedCorpus.podcasting20.episode(guid: "PC20-274")
        let text = HTMLPlainText.structuredText(from: episode.showNotesHTML ?? "")

        #expect(text.contains("the file is <b>15:40</b>; the show is <b>10:08</b> (2:56 – 13:04). <b>Front: 2:56</b> —"))
        #expect(text.contains("(today, 19:02)"))
        #expect(Self.chapters(in: episode.showNotesHTML, duration: episode.duration).isEmpty)
    }

    @Test("Clock times inside prose yield nothing: Podcast Insider PI-151's conference schedule, each line led by a name")
    func clockTimesInsideProse() throws {
        // Its GUID is a URL, and feed hosts stay out of Swift.
        let episode = try FeedCorpus.podcastInsider.episode(titled: "Jeremy Bassetti from All Over The Place Podcast – PI-151")
        let lines = HTMLPlainText.structuredText(from: episode.showNotesHTML ?? "").split(whereSeparator: \.isNewline).map(String.init)

        #expect(lines.contains("Mike: 11:30 on Wednesday, Podcast Distribution. on the solutions stage."))
        #expect(lines.contains("Todd: 10:15 on Thursday, the 15th State of Podcasting"))
        #expect(lines.contains("Todd and Rob Greenlee and guests 4:15 on Thursday: New Media Show Live"))
        #expect(Self.chapters(in: episode.showNotesHTML, duration: episode.duration).isEmpty)
    }

    /// Per feed: episodes whose show notes yield chapters, and the chapters across them.
    private static let census: [String: (episodes: Int, chapters: Int)] = [
        "audacitytopodcast": (0, 0),
        "backupwrapup": (33, 466),
        "buildyoursaas": (32, 361),
        "businesswithoutbs": (187, 2_798),
        "buzzcast": (1, 6),
        "cheekypint": (41, 516),
        "corehappiness": (47, 528),
        "dwarkeshpodcast": (132, 1_489),
        "hrcoffeetime": (122, 1_420),
        "investlikethebest": (561, 11_443),
        "nopriors": (187, 2_237),
        "podcasting20": (1, 4),
        "podcastinsider": (0, 0),
        "pragmaticengineer": (81, 1_632)
    ]

    @Test("Census: how many episodes in each feed yield show-notes chapters, and how many chapters in all", arguments: FeedCorpus.all)
    func census(feed: FeedCorpus) throws {
        let pinned = try #require(Self.census[feed.resource], "\(feed.resource) has no pinned census")
        let lists = try feed.snapshot().episodes
            .map { Self.chapters(in: $0.showNotesHTML, duration: $0.duration) }
            .filter { !$0.isEmpty }

        #expect(lists.count == pinned.episodes)
        #expect(lists.reduce(0) { $0 + $1.count } == pinned.chapters)
    }

    private func chapters(_ feed: FeedCorpus, guid: String) throws -> [EpisodeChapter] {
        let episode = try feed.episode(guid: guid)
        return Self.chapters(in: episode.showNotesHTML, duration: episode.duration)
    }

    private static func chapters(in html: String?, duration: TimeInterval?) -> [EpisodeChapter] {
        ShowNotesChaptersParser.chapters(in: HTMLPlainText.structuredText(from: html ?? ""), duration: duration)
    }
}
