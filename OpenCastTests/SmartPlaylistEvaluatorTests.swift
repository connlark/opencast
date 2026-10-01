import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

/// The smart playlist engine over a real loaded library: each clause alone
/// and combined, the limit, every sort order and its tie-break, lazy inputs,
/// the memo and the 500-episode budget.
@MainActor
@Suite("Smart playlist evaluator")
struct SmartPlaylistEvaluatorTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    /// Alpha and bravo, newest first:
    ///
    /// | id           | age (days) | length (min) | progress            |
    /// | ------------ | ---------- | ------------ | ------------------- |
    /// | a-new        | 1          | 10           | none                |
    /// | a-noduration | 2          | none         | none                |
    /// | b-new        | 3          | 30           | none                |
    /// | b-edge       | 7          | 45           | none                |
    /// | a-mid        | 10         | 40           | in progress         |
    /// | a-old        | 40         | 90           | played flag         |
    /// | b-old        | 100        | 150          | position at the end |
    /// | a-undated    | none       | 20           | none                |
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

    @Test("Age is measured from the injected reference date")
    func ageUsesInjectedNow() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let rule = PlaylistRule(status: .all, maximumAgeDays: 7)

        #expect(
            evaluate(rule, in: fixture, now: Self.now.addingTimeInterval(5 * Self.day))
                == ["a-new", "a-noduration"]
        )
        #expect(evaluate(rule, in: fixture, now: Self.now.addingTimeInterval(40 * Self.day)).isEmpty)
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

    @Test("An un-normalized Downloaded status evaluates as Downloaded Only")
    func downloadedStatusIsNormalized() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let records = [downloadRecord("a-old", state: .completed), downloadRecord("b-new", state: .completed)]

        #expect(evaluate(PlaylistRule(status: .downloaded), in: fixture, downloads: records) == ["b-new", "a-old"])
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

    @Test("Listing every show sorts the union globally, exactly like All Shows")
    func showsUnionIsGloballySorted() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let listed = PlaylistRule(podcastIDs: [Self.bravo.feedURL, Self.alpha.feedURL], status: .all)

        #expect(evaluate(listed, in: fixture) == Self.newestFirstIDs)
        #expect(evaluate(listed, in: fixture) == evaluate(PlaylistRule(status: .all), in: fixture))
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
        // not put tie-b first; the evaluator walks the library's order, which
        // carries the same episode ID tie-break.
        #expect(
            evaluate(PlaylistRule(podcastIDs: [charlie.feedURL, delta.feedURL], status: .all), in: fixture)
                == expected
        )
        #expect(evaluate(PlaylistRule(status: .all, limit: 2), in: fixture) == ["tie-a", "tie-b"])
    }

    @Test("A limit keeps exactly the first episodes of the unlimited order, for every sort, status and show filter")
    func limitMatchesPrefixOfUnlimitedOrder() async throws {
        let fixture = try await makeFixture(shows: [Self.alpha, Self.bravo])
        let showFilters: [[String]?] = [nil, [Self.alpha.feedURL], [Self.alpha.feedURL, Self.bravo.feedURL]]

        for sortOrder in PodcastEpisodeSortOrder.allCases {
            for status in PlaylistRule.statusOptions {
                for podcastIDs in showFilters {
                    let unlimited = evaluate(
                        PlaylistRule(podcastIDs: podcastIDs, status: status, sortOrder: sortOrder),
                        in: fixture
                    )
                    for limit in [1, 2, 3, 5, 100] {
                        let limited = evaluate(
                            PlaylistRule(podcastIDs: podcastIDs, status: status, sortOrder: sortOrder, limit: limit),
                            in: fixture
                        )
                        #expect(limited == Array(unlimited.prefix(limit)), "\(sortOrder) \(status) \(limit)")
                    }
                }
            }
        }
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

    // MARK: - Evaluation and memo

    @Test("An evaluation totals only positive durations")
    func evaluationTotalsPositiveDurations() {
        let evaluation = SmartPlaylistEvaluation(episodes: [
            snapshot("one", duration: 600),
            snapshot("two", duration: nil),
            snapshot("three", duration: 0),
            snapshot("four", duration: 1_200)
        ])

        #expect(evaluation.count == 4)
        #expect(evaluation.totalDuration == 1_800)
        #expect(SmartPlaylistEvaluation.empty.count == 0)
        #expect(SmartPlaylistEvaluation.empty.totalDuration == 0)
    }

    @Test("The memo serves a matching key without recomputing and recomputes when any token moves")
    func memoRecomputesOnlyOnKeyChange() {
        let cache = SmartPlaylistEvaluationCache()
        let key = memoKey()
        var computed: [String] = []
        func compute(_ episodeID: String) -> [EpisodeListItemSnapshot] {
            computed.append(episodeID)
            return [snapshot(episodeID, duration: 60)]
        }

        let first = cache.evaluation(for: "smart", key: key) { compute("first") }
        let hit = cache.evaluation(for: "smart", key: key) { compute("unused") }

        #expect(first.episodes.map(\.episodeID) == ["first"])
        #expect(hit == first)
        #expect(computed == ["first"])
        #expect(cache.computeCount == 1)

        let movedKeys = [
            memoKey(ruleJSON: PlaylistRule(status: .played).encodedJSON()),
            memoKey(episodeRevision: 2),
            memoKey(progressRevision: 1),
            memoKey(downloadsRevision: 1),
            memoKey(referenceDate: Self.now)
        ]
        for (index, movedKey) in movedKeys.enumerated() {
            let recomputed = cache.evaluation(for: "smart", key: movedKey) { compute("moved-\(index)") }
            #expect(recomputed.episodes.map(\.episodeID) == ["moved-\(index)"])
        }
        #expect(cache.computeCount == 1 + movedKeys.count)

        let other = cache.evaluation(for: "other", key: movedKeys[movedKeys.count - 1]) { compute("other") }
        #expect(other.episodes.map(\.episodeID) == ["other"])
        #expect(cache.computeCount == 2 + movedKeys.count)

        cache.remove("smart")
        _ = cache.evaluation(for: "smart", key: movedKeys[movedKeys.count - 1]) { compute("after-remove") }
        _ = cache.evaluation(for: "other", key: movedKeys[movedKeys.count - 1]) { compute("unused") }
        #expect(cache.computeCount == 3 + movedKeys.count)

        cache.removeAll()
        _ = cache.evaluation(for: "other", key: movedKeys[movedKeys.count - 1]) { compute("after-remove-all") }
        #expect(cache.computeCount == 4 + movedKeys.count)
        #expect(!computed.contains("unused"))
    }

    @Test("Smart summary lines give the count and duration and never the unplayed form")
    func smartSummaryLines() {
        let duration: TimeInterval = 8 * 3_600 + 27 * 60

        #expect(PlaylistSummaryText.smartLine(itemCount: 11, totalDuration: duration) == "11 episodes · 8h 27m")
        #expect(
            PlaylistSummaryText.smartSpokenLine(itemCount: 11, totalDuration: duration)
                == "Smart playlist, 11 episodes, 8 hours 27 minutes"
        )
        #expect(PlaylistSummaryText.smartLine(itemCount: 1, totalDuration: 0) == "1 episode")
        #expect(PlaylistSummaryText.smartSpokenLine(itemCount: 1, totalDuration: 0) == "Smart playlist, 1 episode")
        #expect(PlaylistSummaryText.smartLine(itemCount: 0, totalDuration: 0) == "No episodes")
        #expect(PlaylistSummaryText.smartSpokenLine(itemCount: 0, totalDuration: 0) == "Smart playlist, no episodes")
    }

    // MARK: - Budget

    @Test("A 500-episode library evaluates within 50 ms, best of five")
    func fiveHundredEpisodeBudget() async throws {
        let shows = (0 ..< 5).map { showIndex in
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
                    publishedAt: Self.now.addingTimeInterval(-Double(index * 5 + showIndex) * 3_600),
                    duration: TimeInterval(300 + (index * 97 + showIndex * 31) % 7_200),
                    progress: progress
                )
            })
        }
        let fixture = try await makeFixture(shows: shows)
        #expect(fixture.library.episodes.count == 500)
        let rule = PlaylistRule(
            podcastIDs: shows.map(\.feedURL),
            status: .unplayed,
            minimumMinutes: 5,
            maximumAgeDays: 3_650,
            sortOrder: .longestFirst
        )
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
        print("SMART_EVAL_500_MS=\(formatted)")
        // 34 of every show's 100 episodes are played.
        #expect(episodes.count == 330)
        #expect(best < .milliseconds(50))
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
        downloads: [EpisodeDownloadRecord] = [],
        now: Date? = nil
    ) -> [String] {
        SmartPlaylistEvaluator.make(
            rule: rule,
            library: fixture.library,
            downloadRecords: downloads,
            now: now ?? Self.now
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

    private func snapshot(_ episodeID: String, duration: TimeInterval?) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            duration: duration,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    private func memoKey(
        ruleJSON: String = PlaylistRule.default.encodedJSON(),
        episodeRevision: Int = 1,
        progressRevision: Int? = nil,
        downloadsRevision: Int? = nil,
        referenceDate: Date? = nil
    ) -> SmartPlaylistEvaluationKey {
        SmartPlaylistEvaluationKey(
            ruleJSON: ruleJSON,
            episodeRevision: episodeRevision,
            progressRevision: progressRevision,
            downloadsRevision: downloadsRevision,
            referenceDate: referenceDate
        )
    }

    /// Loads the shows into a fresh in-memory library. Progress rows are
    /// inserted directly and saved once, before the library loads them.
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
