import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Smart playlist evaluator")
struct SmartPlaylistEvaluatorTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    private static let alpha = ShowSpec(name: "alpha", episodes: [
        EpisodeSpec(id: "a-new", publishedAt: daysAgo(1), duration: minutes(10)),
        EpisodeSpec(
            id: "a-mid",
            publishedAt: daysAgo(10),
            duration: minutes(40),
            progress: ProgressSpec(position: minutes(10), duration: minutes(40))
        ),
        EpisodeSpec(
            id: "a-old",
            publishedAt: daysAgo(40),
            duration: minutes(90),
            progress: ProgressSpec(position: 0, duration: minutes(90), isPlayed: true)
        ),
        EpisodeSpec(id: "a-undated", publishedAt: nil, duration: minutes(20)),
        EpisodeSpec(id: "a-noduration", publishedAt: daysAgo(2), duration: nil)
    ])
    private static let bravo = ShowSpec(name: "bravo", episodes: [
        EpisodeSpec(id: "b-new", publishedAt: daysAgo(3), duration: minutes(30)),
        EpisodeSpec(id: "b-edge", publishedAt: daysAgo(7), duration: minutes(45)),
        // No stored duration: completion falls back to the episode's own.
        EpisodeSpec(
            id: "b-old",
            publishedAt: daysAgo(100),
            duration: minutes(150),
            progress: ProgressSpec(position: minutes(150) - 10, duration: nil)
        )
    ])
    private static let newestFirstIDs = [
        "a-new", "a-noduration", "b-new", "b-edge", "a-mid", "a-old", "b-old", "a-undated"
    ]

    // MARK: - Clauses

    @Test("Every played-state option filters on the library's progress")
    func statusClauseAlone() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(evaluate(PlaylistRule(status: .all), in: fixture) == Self.newestFirstIDs)
        #expect(
            evaluate(PlaylistRule(status: .unplayed), in: fixture)
                == ["a-new", "a-noduration", "b-new", "b-edge", "a-mid", "a-undated"]
        )
        #expect(evaluate(PlaylistRule(status: .inProgress), in: fixture) == ["a-mid"])
        #expect(evaluate(PlaylistRule(status: .played), in: fixture) == ["a-old", "b-old"])
    }

    @Test("Length includes its lower bound, excludes its upper bound, and skips episodes without a duration")
    func lengthClauseAlone() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(evaluate(PlaylistRule(status: .all, maximumMinutes: 30), in: fixture) == ["a-new", "a-undated"])
        #expect(
            evaluate(PlaylistRule(status: .all, minimumMinutes: 30), in: fixture)
                == ["b-new", "b-edge", "a-mid", "a-old", "b-old"]
        )
        #expect(
            evaluate(PlaylistRule(status: .all, minimumMinutes: 30, maximumMinutes: 45), in: fixture)
                == ["b-new", "a-mid"]
        )
        let anyLength = evaluate(PlaylistRule(status: .all, minimumMinutes: 0), in: fixture)
        #expect(!anyLength.contains("a-noduration"))
        #expect(anyLength.count == Self.newestFirstIDs.count - 1)
    }

    @Test("Age keeps episodes released on or after the cutoff and skips undated ones")
    func ageClauseAlone() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(
            evaluate(PlaylistRule(status: .all, maximumAgeDays: 7), in: fixture)
                == ["a-new", "a-noduration", "b-new", "b-edge"]
        )
        #expect(
            evaluate(PlaylistRule(status: .all, maximumAgeDays: 365), in: fixture)
                == Self.newestFirstIDs.filter { $0 != "a-undated" }
        )
    }

    @Test("Downloaded Only keeps completed downloads and ignores in-flight, paused, failed and missing ones")
    func downloadedClauseUsesCompletedRecordsOnly() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let records = [
            downloadRecord("a-new", state: .completed),
            downloadRecord("b-old", state: .completed),
            downloadRecord("b-new", state: .downloading),
            downloadRecord("b-edge", state: .paused),
            downloadRecord("a-mid", state: .failed),
            downloadRecord("a-undated", state: .missing),
            downloadRecord("unsubscribed", state: .completed)
        ]

        #expect(
            evaluate(PlaylistRule(status: .all, downloadedOnly: true), in: fixture, downloads: records)
                == ["a-new", "b-old"]
        )
        #expect(
            evaluate(PlaylistRule(status: .unplayed, downloadedOnly: true), in: fixture, downloads: records)
                == ["a-new"]
        )
        #expect(evaluate(PlaylistRule(status: .all, downloadedOnly: true), in: fixture).isEmpty)
        #expect(evaluate(PlaylistRule(status: .all), in: fixture, downloads: records) == Self.newestFirstIDs)
    }

    @Test("Shows restrict the evaluation to the listed canonical feed IDs")
    func showsClauseRestrictsToListedIDs() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(
            evaluate(PlaylistRule(podcastIDs: [Self.bravo.feedURL], status: .all), in: fixture)
                == ["b-new", "b-edge", "b-old"]
        )
        #expect(
            evaluate(
                PlaylistRule(podcastIDs: [Self.bravo.feedURL, "https://example.com/unsubscribed.xml"], status: .all),
                in: fixture
            ) == ["b-new", "b-edge", "b-old"]
        )
        #expect(
            evaluate(PlaylistRule(podcastIDs: [Self.bravo.feedURL, Self.bravo.feedURL], status: .all), in: fixture)
                == ["b-new", "b-edge", "b-old"]
        )
        let variantID = Self.bravo.feedURL.replacing("https://", with: "http://")
        #expect(evaluate(PlaylistRule(podcastIDs: [variantID], status: .all), in: fixture).isEmpty)
    }

    @Test("Clauses combine with AND")
    func clausesCombine() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let rule = PlaylistRule(
            podcastIDs: [Self.alpha.feedURL],
            status: .unplayed,
            maximumMinutes: 45,
            maximumAgeDays: 30,
            sortOrder: .oldestFirst
        )
        let records = [
            downloadRecord("a-new", state: .completed),
            downloadRecord("b-new", state: .completed),
            downloadRecord("a-old", state: .completed)
        ]
        var downloadedRule = rule
        downloadedRule.downloadedOnly = true

        #expect(evaluate(rule, in: fixture) == ["a-mid", "a-new"])
        #expect(evaluate(downloadedRule, in: fixture, downloads: records) == ["a-new"])
    }

    // MARK: - Sort and limit

    @Test("Every sort order applies over the whole evaluation")
    func everySortOrder() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(evaluate(PlaylistRule(status: .all, sortOrder: .newestFirst), in: fixture) == Self.newestFirstIDs)
        #expect(
            evaluate(PlaylistRule(status: .all, sortOrder: .oldestFirst), in: fixture)
                == ["b-old", "a-old", "a-mid", "b-edge", "b-new", "a-noduration", "a-new", "a-undated"]
        )
        #expect(
            evaluate(PlaylistRule(status: .all, sortOrder: .longestFirst), in: fixture)
                == ["b-old", "a-old", "b-edge", "a-mid", "b-new", "a-undated", "a-new", "a-noduration"]
        )
        #expect(
            evaluate(PlaylistRule(status: .all, sortOrder: .shortestFirst), in: fixture)
                == ["a-new", "a-undated", "b-new", "a-mid", "b-edge", "a-old", "b-old", "a-noduration"]
        )
    }

    @Test("Newest First breaks equal-date and equal-title ties by episode ID, for All Shows, listed shows and a limit")
    func newestFirstTieBreak() async throws {
        let sameDay = Self.daysAgo(2)
        let charlie = ShowSpec(name: "charlie", episodes: [
            EpisodeSpec(id: "tie-c", publishedAt: sameDay, duration: Self.minutes(30)),
            EpisodeSpec(id: "tie-a", publishedAt: sameDay, duration: Self.minutes(30)),
            EpisodeSpec(id: "same-z", title: "Same Title", publishedAt: nil, duration: Self.minutes(30))
        ])
        let delta = ShowSpec(name: "delta", episodes: [
            EpisodeSpec(id: "tie-b", publishedAt: sameDay, duration: Self.minutes(30)),
            EpisodeSpec(id: "same-m", title: "Same Title", publishedAt: nil, duration: Self.minutes(30))
        ])
        let fixture = try await makeFixture(shows: [charlie, delta])
        let expected = ["tie-a", "tie-b", "tie-c", "same-m", "same-z"]

        #expect(evaluate(PlaylistRule(status: .all), in: fixture) == expected)
        // Charlie lists tie-c before delta's tie-b, so feed order alone would
        // not put tie-b first.
        #expect(
            evaluate(PlaylistRule(podcastIDs: [charlie.feedURL, delta.feedURL], status: .all), in: fixture)
                == expected
        )
        #expect(evaluate(PlaylistRule(status: .all, limit: 2), in: fixture) == ["tie-a", "tie-b"])
    }

    @Test("The limit keeps the first episodes in rule order")
    func limitAppliesAfterSorting() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(evaluate(PlaylistRule(status: .all, limit: 3), in: fixture) == ["a-new", "a-noduration", "b-new"])
        #expect(
            evaluate(PlaylistRule(status: .all, sortOrder: .oldestFirst, limit: 2), in: fixture)
                == ["b-old", "a-old"]
        )
        #expect(evaluate(PlaylistRule(status: .all, limit: 100), in: fixture) == Self.newestFirstIDs)
        #expect(evaluate(PlaylistRule(status: .all, limit: nil), in: fixture) == Self.newestFirstIDs)
        #expect(
            evaluate(.default, in: fixture) == ["a-new", "a-noduration", "b-new", "b-edge", "a-mid", "a-undated"]
        )
    }

    // MARK: - Priority

    @Test("Prioritized shows lead in rank order, each in the sort order, then every other episode")
    func priorityGroupsRankedShowsFirst() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let alphaIDs = ["a-new", "a-noduration", "a-mid", "a-old", "a-undated"]
        let bravoIDs = ["b-new", "b-edge", "b-old"]

        #expect(
            evaluate(PlaylistRule(priorityPodcastIDs: [Self.bravo.feedURL], status: .all), in: fixture)
                == bravoIDs + alphaIDs
        )
        #expect(
            evaluate(PlaylistRule(priorityPodcastIDs: [Self.alpha.feedURL], status: .all), in: fixture)
                == alphaIDs + bravoIDs
        )
        let bravoThenAlpha = evaluate(
            PlaylistRule(priorityPodcastIDs: [Self.bravo.feedURL, Self.alpha.feedURL], status: .all),
            in: fixture
        )
        let alphaThenBravo = evaluate(
            PlaylistRule(priorityPodcastIDs: [Self.alpha.feedURL, Self.bravo.feedURL], status: .all),
            in: fixture
        )
        #expect(bravoThenAlpha == bravoIDs + alphaIDs)
        #expect(alphaThenBravo == alphaIDs + bravoIDs)
    }

    @Test(
        "Every sort order still applies inside each prioritized show and across the rest",
        arguments: [
            (PodcastEpisodeSortOrder.newestFirst, ["b-new", "b-edge", "b-old", "a-new", "a-noduration", "a-mid", "a-old", "a-undated"]),
            (.oldestFirst, ["b-old", "b-edge", "b-new", "a-old", "a-mid", "a-noduration", "a-new", "a-undated"]),
            (.longestFirst, ["b-old", "b-edge", "b-new", "a-old", "a-mid", "a-undated", "a-new", "a-noduration"]),
            (.shortestFirst, ["b-new", "b-edge", "b-old", "a-new", "a-undated", "a-mid", "a-old", "a-noduration"])
        ]
    )
    func priorityKeepsTheSortInsideEachShow(sortOrder: PodcastEpisodeSortOrder, expected: [String]) async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])

        #expect(
            evaluate(
                PlaylistRule(priorityPodcastIDs: [Self.bravo.feedURL], status: .all, sortOrder: sortOrder),
                in: fixture
            ) == expected
        )
    }

    @Test("The limit applies after priority, so ranked episodes fill it first")
    func limitKeepsPriorityFirst() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let ranked = PlaylistRule(priorityPodcastIDs: [Self.bravo.feedURL], status: .all)

        var limited = ranked
        limited.limit = 2
        #expect(evaluate(limited, in: fixture) == ["b-new", "b-edge"])
        limited.limit = 4
        #expect(evaluate(limited, in: fixture) == ["b-new", "b-edge", "b-old", "a-new"])

        var defaultRule = PlaylistRule.default
        defaultRule.priorityPodcastIDs = [Self.bravo.feedURL]
        #expect(
            evaluate(defaultRule, in: fixture) == ["b-new", "b-edge", "a-new", "a-noduration", "a-mid", "a-undated"]
        )
    }

    @Test("Equal dates inside a prioritized show still fall back to the episode ID")
    func priorityKeepsTheTieBreak() async throws {
        let sameDay = Self.daysAgo(2)
        let charlie = ShowSpec(name: "charlie", episodes: [
            EpisodeSpec(id: "tie-c", publishedAt: sameDay, duration: Self.minutes(30)),
            EpisodeSpec(id: "tie-a", publishedAt: sameDay, duration: Self.minutes(30))
        ])
        let delta = ShowSpec(name: "delta", episodes: [
            EpisodeSpec(id: "tie-d", publishedAt: sameDay, duration: Self.minutes(30)),
            EpisodeSpec(id: "tie-b", publishedAt: sameDay, duration: Self.minutes(30))
        ])
        let fixture = try await makeFixture(shows: [charlie, delta])
        // Downloaded Only walks a set of download IDs, so its source order is
        // arbitrary and only the evaluator's tie-break orders equal dates.
        let records = ["tie-a", "tie-b", "tie-c", "tie-d"].map { downloadRecord($0, state: .completed) }
        var rule = PlaylistRule(priorityPodcastIDs: [charlie.feedURL], status: .all, downloadedOnly: true)

        #expect(evaluate(rule, in: fixture, downloads: records) == ["tie-a", "tie-c", "tie-b", "tie-d"])
        rule.limit = 3
        #expect(evaluate(rule, in: fixture, downloads: records) == ["tie-a", "tie-c", "tie-b"])
    }

    // MARK: - Inputs

    @Test("Download records and the reference date are read once, and only by rules that need them")
    func lazyInputs() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        var downloadReads = 0
        var dateReads = 0
        func downloadRecords() -> [EpisodeDownloadRecord] {
            downloadReads += 1
            return []
        }
        func referenceDate() -> Date {
            dateReads += 1
            return Self.now
        }

        _ = SmartPlaylistEvaluator.make(
            rule: PlaylistRule(status: .unplayed, minimumMinutes: 5),
            library: fixture.library,
            downloadRecords: downloadRecords(),
            now: referenceDate()
        )

        #expect(downloadReads == 0)
        #expect(dateReads == 0)

        _ = SmartPlaylistEvaluator.make(
            rule: PlaylistRule(status: .all, downloadedOnly: true, maximumAgeDays: 30),
            library: fixture.library,
            downloadRecords: downloadRecords(),
            now: referenceDate()
        )

        #expect(downloadReads == 1)
        #expect(dateReads == 1)
    }

    // MARK: - Budget

    @Test("A 500-episode library evaluates within 50 ms, best of five")
    func fiveHundredEpisodeBudget() async throws {
        let shows = Self.budgetShows
        let fixture = try await makeFixture(shows: shows)
        #expect(fixture.library.episodes.count == 500)
        let rule = PlaylistRule(
            podcastIDs: shows.map(\.feedURL),
            status: .unplayed,
            minimumMinutes: 5,
            maximumAgeDays: 3_650,
            sortOrder: .longestFirst
        )

        let (best, episodes) = measureBestOfFive(rule, in: fixture, label: "SMART_EVAL_500_MS")

        // 34 of every show's 100 episodes are played.
        #expect(episodes.count == 330)
        #expect(best < .milliseconds(50))
    }

    @Test("A 500-episode library with two prioritized shows and no limit evaluates within 50 ms, best of five")
    func fiveHundredEpisodePriorityBudget() async throws {
        let shows = Self.budgetShows
        let fixture = try await makeFixture(shows: shows)
        #expect(fixture.library.episodes.count == 500)
        let rule = PlaylistRule(priorityPodcastIDs: [shows[3].feedURL, shows[1].feedURL], status: .unplayed)

        let (best, episodes) = measureBestOfFive(rule, in: fixture, label: "SMART_EVAL_500_PRIORITY_MS")

        #expect(episodes.count == 330)
        #expect(episodes.prefix(66).allSatisfy { $0.podcastID == shows[3].feedURL })
        #expect(episodes.dropFirst(66).prefix(66).allSatisfy { $0.podcastID == shows[1].feedURL })
        #expect(best < .milliseconds(50))
    }

    private static let budgetShows = (0 ..< 5).map { showIndex in
        ShowSpec(name: "budget-\(showIndex)", episodes: (0 ..< 100).map { index in
            let progress: ProgressSpec? = if index % 3 == 0 {
                ProgressSpec(position: 0, duration: nil, isPlayed: true)
            } else if index % 5 == 1 {
                ProgressSpec(position: 60, duration: nil)
            } else {
                nil
            }
            return EpisodeSpec(
                id: "budget-\(showIndex)-\(index)",
                publishedAt: now.addingTimeInterval(-Double(index * 5 + showIndex) * 3_600),
                duration: TimeInterval(300 + (index * 97 + showIndex * 31) % 7_200),
                progress: progress
            )
        })
    }

    private func measureBestOfFive(
        _ rule: PlaylistRule,
        in fixture: Fixture,
        label: String
    ) -> (best: Duration, episodes: [EpisodeListItemSnapshot]) {
        let clock = ContinuousClock()
        var best = Duration.seconds(60)
        var episodes: [EpisodeListItemSnapshot] = []

        for _ in 0 ..< 5 {
            let elapsed = clock.measure {
                episodes = SmartPlaylistEvaluator.make(
                    rule: rule,
                    library: fixture.library,
                    downloadRecords: [],
                    now: Self.now
                )
            }
            best = min(best, elapsed)
        }

        let milliseconds = best / .milliseconds(1)
        let formatted = milliseconds.formatted(
            .number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))
        )
        print("\(label)=\(formatted)")
        return (best, episodes)
    }

    // MARK: - Fixtures

    private struct ShowSpec {
        let name: String
        let episodes: [EpisodeSpec]

        var feedURL: String {
            "https://example.com/smart-\(name).xml"
        }
    }

    private struct EpisodeSpec {
        let id: String
        var title: String?
        let publishedAt: Date?
        let duration: TimeInterval?
        var progress: ProgressSpec?
    }

    private struct ProgressSpec {
        let position: TimeInterval
        let duration: TimeInterval?
        var isPlayed = false
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let library: LibraryStore
    }

    private static func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * day)
    }

    private static func minutes(_ minutes: Double) -> TimeInterval {
        minutes * 60
    }

    private func evaluate(
        _ rule: PlaylistRule,
        in fixture: Fixture,
        downloads: [EpisodeDownloadRecord] = []
    ) -> [String] {
        SmartPlaylistEvaluator.make(
            rule: rule,
            library: fixture.library,
            downloadRecords: downloads,
            now: Self.now
        ).map(\.episodeID)
    }

    private func downloadRecord(_ episodeID: String, state: EpisodeDownloadState) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: "https://example.com/smart-downloads.xml",
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            state: state
        )
    }

    private func makeFixture(shows: [ShowSpec]) async throws -> Fixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        for show in shows {
            try await cache.upsertCache(from: feedSnapshot(for: show), refreshedAt: Self.now)
            context.insert(
                SubscriptionRecord(
                    feedURL: show.feedURL,
                    title: "Show \(show.name)",
                    subscribedAt: Self.daysAgo(3_650)
                )
            )
            for episode in show.episodes {
                guard let progress = episode.progress else {
                    continue
                }
                context.insert(
                    EpisodeProgressRecord(
                        episodeID: episode.id,
                        podcastID: show.feedURL,
                        position: progress.position,
                        duration: progress.duration,
                        isPlayed: progress.isPlayed,
                        updatedAt: Self.now.addingTimeInterval(-60 * 60)
                    )
                )
            }
        }
        try context.save()
        let library = LibraryStore(localCache: cache, now: { Self.now })
        #expect(await library.load(modelContext: context))
        return Fixture(container: container, context: context, library: library)
    }

    private func feedSnapshot(for show: ShowSpec) throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: show.feedURL))
        let podcast = Podcast(
            id: PodcastID(rawValue: show.feedURL),
            feedURL: feedURL,
            title: "Show \(show.name)"
        )
        return FeedSnapshot(
            podcast: podcast,
            episodes: show.episodes.map { episode in
                Episode(
                    id: EpisodeID(rawValue: episode.id),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: episode.title ?? "Episode \(episode.id)",
                    publishedAt: episode.publishedAt,
                    duration: episode.duration,
                    audioURL: URL(string: "https://example.com/\(episode.id).mp3"),
                    guid: episode.id
                )
            }
        )
    }
}
