import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

/// Store-level contract for the Library's new-episode badges and the Recent
/// Episodes sort: what counts, how the reference date moves the window, and
/// that count readers see every way progress can change underneath them.
@MainActor
@Suite("Library new-episode counts")
struct LibraryNewEpisodeCountTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    @Test("Counts incomplete episodes released since the follow and within the window")
    func countsEligibleIncompleteEpisodesPerShow() async throws {
        let alpha = ShowFixture(name: "alpha", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "alpha-unplayed", publishedAt: at(days: -1)),
            EpisodeFixture(
                id: "alpha-started",
                publishedAt: at(days: -2),
                progress: ProgressFixture(position: 120, duration: 600)
            ),
            EpisodeFixture(
                id: "alpha-played",
                publishedAt: at(days: -3),
                progress: ProgressFixture(position: 0, duration: 600, isPlayed: true)
            ),
            // No stored duration: completion falls back to the episode's own.
            EpisodeFixture(
                id: "alpha-near-end",
                publishedAt: at(days: -4),
                duration: 600,
                progress: ProgressFixture(position: 570, duration: nil)
            ),
            EpisodeFixture(id: "alpha-expired", publishedAt: at(days: -31)),
            EpisodeFixture(id: "alpha-undated", publishedAt: nil),
            EpisodeFixture(id: "alpha-scheduled", publishedAt: at(days: 1))
        ])
        let bravo = ShowFixture(name: "bravo", subscribedAt: at(days: -5), episodes: [
            EpisodeFixture(id: "bravo-after-follow", publishedAt: at(days: -1)),
            EpisodeFixture(id: "bravo-at-follow", publishedAt: at(days: -5)),
            EpisodeFixture(id: "bravo-before-follow", publishedAt: at(days: -10))
        ])
        let charlie = ShowFixture(name: "charlie", subscribedAt: at(days: -60), episodes: [
            EpisodeFixture(id: "charlie-window-edge", publishedAt: at(days: -30)),
            EpisodeFixture(
                id: "charlie-played",
                publishedAt: at(days: -2),
                progress: ProgressFixture(position: 600, duration: 600, isPlayed: true)
            ),
            EpisodeFixture(id: "charlie-past-edge", publishedAt: at(days: -30).addingTimeInterval(-1))
        ])
        let shows = [alpha, bravo, charlie]
        let fixture = try await makeFixture(shows: shows)

        let counts = try shows.map { show in
            let subscription = try fixture.subscription(for: show)
            return fixture.library.newEpisodeCount(for: subscription)
        }

        #expect(fixture.library.newEpisodeReferenceDate == Self.start)
        #expect(counts == [2, 2, 1])
        #expect(counts == shows.map { oracleCount(for: $0, asOf: Self.start) })
    }

    @Test("Latest released date skips scheduled and undated episodes and ignores played state")
    func latestReleasedEpisodeDate() async throws {
        let mixed = ShowFixture(name: "mixed", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "mixed-scheduled", publishedAt: at(days: 2)),
            EpisodeFixture(
                id: "mixed-latest-released",
                publishedAt: at(days: -3),
                progress: ProgressFixture(position: 600, duration: 600, isPlayed: true)
            ),
            EpisodeFixture(id: "mixed-older", publishedAt: at(days: -10)),
            EpisodeFixture(id: "mixed-undated", publishedAt: nil)
        ])
        let onlyScheduled = ShowFixture(name: "only-scheduled", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "only-scheduled-1", publishedAt: at(days: 1))
        ])
        let onlyUndated = ShowFixture(name: "only-undated", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "only-undated-1", publishedAt: nil)
        ])
        let fixture = try await makeFixture(shows: [mixed, onlyScheduled, onlyUndated])
        let library = fixture.library

        #expect(library.latestReleasedEpisodeDate(forPodcastID: mixed.feedURL) == at(days: -3))
        #expect(library.latestReleasedEpisodeDate(forPodcastID: onlyScheduled.feedURL) == nil)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: onlyUndated.feedURL) == nil)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: "https://example.com/unknown.xml") == nil)
    }

    @Test("Progress writes move the count as episodes complete and clear")
    func progressWritesMoveTheCount() async throws {
        let target = ShowFixture(name: "target", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "target-1", publishedAt: at(days: -1)),
            EpisodeFixture(id: "target-2", publishedAt: at(days: -2)),
            EpisodeFixture(id: "target-3", publishedAt: at(days: -3))
        ])
        let other = ShowFixture(name: "other", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "other-1", publishedAt: at(days: -1))
        ])
        let fixture = try await makeFixture(shows: [target, other])
        let library = fixture.library
        let context = fixture.context
        let targetSubscription = try fixture.subscription(for: target)
        let otherSubscription = try fixture.subscription(for: other)
        let first = try #require(library.episode(with: "target-1"))
        #expect(library.newEpisodeCount(for: targetSubscription) == 3)

        #expect(library.markEpisodePlayed(first, modelContext: context))
        #expect(library.newEpisodeCount(for: targetSubscription) == 2)

        #expect(library.clearProgress(for: first, modelContext: context))
        #expect(library.newEpisodeCount(for: targetSubscription) == 3)

        // Partway through still counts; crossing the near-end threshold completes it.
        #expect(library.updateProgress(
            episodeID: "target-2",
            podcastID: target.feedURL,
            position: 100,
            duration: 600,
            modelContext: context
        ))
        #expect(library.newEpisodeCount(for: targetSubscription) == 3)
        #expect(library.updateProgress(
            episodeID: "target-2",
            podcastID: target.feedURL,
            position: 590,
            duration: 600,
            modelContext: context
        ))
        #expect(library.newEpisodeCount(for: targetSubscription) == 2)

        #expect(library.markAllPlayed(forPodcastID: target.feedURL, modelContext: context))
        #expect(library.newEpisodeCount(for: targetSubscription) == 0)
        #expect(library.newEpisodeCount(for: otherSubscription) == 1)
    }

    @Test("Marking an eligible episode played invalidates a count reader")
    func markingPlayedInvalidatesCountReader() async throws {
        let show = ShowFixture(name: "observed", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "observed-1", publishedAt: at(days: -1)),
            EpisodeFixture(id: "observed-2", publishedAt: at(days: -2))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        let episode = try #require(library.episode(with: "observed-1"))

        await confirmation("the count reader invalidates") { invalidated in
            withObservationTracking {
                _ = library.newEpisodeCount(for: subscription)
            } onChange: {
                invalidated()
            }
            library.markEpisodePlayed(episode, modelContext: fixture.context)
        }
        #expect(library.newEpisodeCount(for: subscription) == 1)
    }

    @Test("In-place progress edits invalidate a count reader without a republication")
    func inPlaceProgressEditsInvalidateCountReader() async throws {
        let show = ShowFixture(name: "in-place", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(
                id: "in-place-deferred",
                publishedAt: at(days: -1),
                progress: ProgressFixture(position: 100, duration: 600)
            ),
            EpisodeFixture(
                id: "in-place-direct",
                publishedAt: at(days: -2),
                progress: ProgressFixture(position: 100, duration: 600)
            ),
            EpisodeFixture(id: "in-place-untouched", publishedAt: at(days: -3))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        let deferredRecord = try #require(library.progressRecord(for: "in-place-deferred"))
        #expect(library.newEpisodeCount(for: subscription) == 3)

        // A deferred flush (Now Playing presented, scene not on screen) saves
        // the indexed record in place and leaves the projection unpublished.
        await confirmation("a deferred flush invalidates the count reader") { invalidated in
            withObservationTracking {
                _ = library.newEpisodeCount(for: subscription)
            } onChange: {
                invalidated()
            }
            library.updateProgress(
                episodeID: "in-place-deferred",
                podcastID: show.feedURL,
                position: 590,
                duration: 600,
                modelContext: fixture.context,
                refreshObservableProgress: false
            )
        }
        #expect(library.progressRecord(for: "in-place-deferred") === deferredRecord)
        #expect(deferredRecord.isPlayed)
        #expect(library.newEpisodeCount(for: subscription) == 2)

        // An edit that lands directly on the live model object.
        let directRecord = try #require(library.progressRecord(for: "in-place-direct"))
        await confirmation("a live model edit invalidates the count reader") { invalidated in
            withObservationTracking {
                _ = library.newEpisodeCount(for: subscription)
            } onChange: {
                invalidated()
            }
            directRecord.isPlayed = true
        }
        #expect(library.newEpisodeCount(for: subscription) == 1)
    }

    @Test("A show with nothing to count still invalidates when an eligible episode arrives")
    func emptyShowInvalidatesWhenEpisodeArrives() async throws {
        let show = ShowFixture(name: "arriving", subscribedAt: at(days: -90), episodes: [])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        #expect(library.newEpisodeCount(for: subscription) == 0)
        let arrived = ShowFixture(name: "arriving", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "arriving-1", publishedAt: at(days: -1))
        ])

        try await confirmation("the zero count reader invalidates") { invalidated in
            withObservationTracking {
                _ = library.newEpisodeCount(for: subscription)
            } onChange: {
                invalidated()
            }
            try await fixture.cache.upsertCache(from: makeFeedSnapshot(for: arrived), refreshedAt: Self.start)
            try await library.reloadPersistedData(modelContext: fixture.context)
        }
        #expect(library.newEpisodeCount(for: subscription) == 1)
    }

    @Test("Synced progress imports and follow-date edits reach the count")
    func syncedImportsReachTheCount() async throws {
        let show = ShowFixture(name: "synced", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(
                id: "synced-updated",
                publishedAt: at(days: -1),
                progress: ProgressFixture(position: 100, duration: 600)
            ),
            EpisodeFixture(id: "synced-inserted", publishedAt: at(days: -2)),
            EpisodeFixture(
                id: "synced-live",
                publishedAt: at(days: -3),
                progress: ProgressFixture(position: 100, duration: 600)
            ),
            EpisodeFixture(id: "synced-kept", publishedAt: at(days: -4)),
            EpisodeFixture(id: "synced-cut", publishedAt: at(days: -6))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        #expect(library.newEpisodeCount(for: subscription) == 5)

        // Another context completes an existing row. The store's refetch can
        // find its live object already current and report no progress
        // change; the count follows the row either way.
        let importContext = ModelContext(fixture.container)
        let importedRecord = try #require(
            importContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
                .first(where: { $0.episodeID == "synced-updated" })
        )
        importedRecord.position = 600
        importedRecord.isPlayed = true
        importedRecord.updatedAt = Self.start.addingTimeInterval(60)
        try importContext.save()
        // The refetch refreshes the store's live object without an
        // Observation notification of its own; the reader still invalidates.
        await confirmation("an imported edit invalidates the count reader") { invalidated in
            withObservationTracking {
                _ = library.newEpisodeCount(for: subscription)
            } onChange: {
                invalidated()
            }
            _ = try? library.reloadSyncedUserData(modelContext: fixture.context)
        }
        #expect(library.newEpisodeCount(for: subscription) == 4)

        // Another context inserts a played row for an episode with no progress yet.
        importContext.insert(EpisodeProgressRecord(
            episodeID: "synced-inserted",
            podcastID: show.feedURL,
            position: 600,
            duration: 600,
            isPlayed: true,
            updatedAt: Self.start.addingTimeInterval(120)
        ))
        try importContext.save()
        let insertResult = try library.reloadSyncedUserData(modelContext: fixture.context)
        #expect(insertResult.progressRecordsChanged)
        #expect(library.newEpisodeCount(for: subscription) == 3)

        // The store's own live object edited in place: the reload sees no
        // progress change, and the count moves anyway.
        let liveRecord = try #require(library.progressRecord(for: "synced-live"))
        liveRecord.isPlayed = true
        liveRecord.updatedAt = Self.start.addingTimeInterval(180)
        try fixture.context.save()
        let liveResult = try library.reloadSyncedUserData(modelContext: fixture.context)
        #expect(!liveResult.progressRecordsChanged)
        #expect(library.newEpisodeCount(for: subscription) == 2)

        // A later follow date on the same subscription object, with the
        // active feed set unchanged, moves the cutoff.
        subscription.subscribedAt = at(days: -5)
        try fixture.context.save()
        let cutoffResult = try library.reloadSyncedUserData(modelContext: fixture.context)
        #expect(!cutoffResult.activePodcastIDsChanged)
        #expect(library.newEpisodeCount(for: subscription) == 1)
    }

    @Test("An imported follow date invalidates the count, and duplicates use the newest")
    func importedFollowDatesAndDuplicates() async throws {
        let show = ShowFixture(name: "follow", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "follow-1", publishedAt: at(days: -1)),
            EpisodeFixture(id: "follow-3", publishedAt: at(days: -3)),
            EpisodeFixture(id: "follow-10", publishedAt: at(days: -10))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        #expect(library.newEpisodeCount(for: subscription) == 3)

        // Another context moves the follow date; the store's refetch finds the
        // same live record, so only the copied cutoff can report the change.
        let importContext = ModelContext(fixture.container)
        let importedSubscription = try #require(
            importContext.fetch(FetchDescriptor<SubscriptionRecord>())
                .first(where: { $0.feedURL == show.feedURL })
        )
        importedSubscription.subscribedAt = at(days: -5)
        try importContext.save()
        await confirmation("an imported follow date invalidates the count reader") { invalidated in
            withObservationTracking {
                _ = library.newEpisodeCount(for: subscription)
            } onChange: {
                invalidated()
            }
            _ = try? library.reloadSyncedUserData(modelContext: fixture.context)
        }
        #expect(library.newEpisodeCount(for: subscription) == 2)

        // A duplicate record for the same feed, followed later, sets the
        // cutoff for every row of that feed until repair merges them.
        let duplicate = SubscriptionRecord(feedURL: show.feedURL, title: show.title, subscribedAt: at(days: -2))
        fixture.context.insert(duplicate)
        try fixture.context.save()
        try await library.reloadPersistedData(modelContext: fixture.context)
        #expect(library.subscriptions.count(where: { $0.feedURL == show.feedURL }) == 2)
        #expect(library.newEpisodeCount(for: subscription) == 1)
        #expect(library.newEpisodeCount(for: duplicate) == 1)
    }

    @Test("The reference date moves only at checkpoints and carries the window with it")
    func referenceDateCheckpoints() async throws {
        let show = ShowFixture(name: "timed", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "timed-recent", publishedAt: at(days: -1)),
            EpisodeFixture(id: "timed-older", publishedAt: at(days: -20)),
            EpisodeFixture(id: "timed-scheduled", publishedAt: at(days: 2))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let clock = fixture.clock
        let subscription = try fixture.subscription(for: show)
        #expect(library.newEpisodeReferenceDate == Self.start)
        #expect(library.newEpisodeCount(for: subscription) == 2)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: show.feedURL) == at(days: -1))

        // Sub-minute movement in either direction is ignored.
        clock.now = Self.start.addingTimeInterval(59)
        library.advanceNewEpisodeReferenceDate()
        #expect(library.newEpisodeReferenceDate == Self.start)
        clock.now = Self.start.addingTimeInterval(-59)
        library.advanceNewEpisodeReferenceDate()
        #expect(library.newEpisodeReferenceDate == Self.start)

        // Once the clock passes a scheduled episode, it counts and leads the sort.
        clock.now = at(days: 3)
        library.advanceNewEpisodeReferenceDate()
        #expect(library.newEpisodeReferenceDate == at(days: 3))
        #expect(library.newEpisodeCount(for: subscription) == 3)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: show.feedURL) == at(days: 2))

        // A backward correction of a minute or more is taken.
        clock.now = at(days: 3).addingTimeInterval(-60)
        library.advanceNewEpisodeReferenceDate()
        #expect(library.newEpisodeReferenceDate == at(days: 3).addingTimeInterval(-60))

        // Thirty-one days on, everything released before the new window expires.
        clock.now = at(days: 31)
        library.advanceNewEpisodeReferenceDate()
        #expect(library.newEpisodeReferenceDate == at(days: 31))
        #expect(library.newEpisodeCount(for: subscription) == 1)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: show.feedURL) == at(days: 2))

        // A publication resets it to the clock regardless of the threshold.
        clock.now = at(days: 31).addingTimeInterval(10)
        try await library.reloadPersistedData(modelContext: fixture.context)
        #expect(library.newEpisodeReferenceDate == clock.now)
    }

    @Test("A data nuke clears counts and release dates")
    func dataNukeClearsCounts() async throws {
        let show = ShowFixture(name: "nuked", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "nuked-1", publishedAt: at(days: -1))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        #expect(library.newEpisodeCount(for: subscription) == 1)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: show.feedURL) != nil)

        fixture.clock.now = Self.start.addingTimeInterval(30)
        library.resetAfterDataNuke()

        #expect(library.newEpisodeCount(for: subscription) == 0)
        #expect(library.latestReleasedEpisodeDate(forPodcastID: show.feedURL) == nil)
        #expect(library.newEpisodeReferenceDate == fixture.clock.now)
    }

    @Test("Reading counts and release dates never saves")
    func derivedReadsNeverSave() async throws {
        let show = ShowFixture(name: "read-only", subscribedAt: at(days: -90), episodes: [
            EpisodeFixture(id: "read-only-1", publishedAt: at(days: -1)),
            EpisodeFixture(
                id: "read-only-2",
                publishedAt: at(days: -2),
                progress: ProgressFixture(position: 590, duration: 600)
            ),
            EpisodeFixture(id: "read-only-3", publishedAt: at(days: 1))
        ])
        let fixture = try await makeFixture(shows: [show])
        let library = fixture.library
        let subscription = try fixture.subscription(for: show)
        let savesBeforeReads = library.syncedStoreSelfSaveCount

        for _ in 0..<3 {
            _ = library.newEpisodeCount(for: subscription)
            _ = library.latestReleasedEpisodeDate(forPodcastID: show.feedURL)
        }
        fixture.clock.now = at(days: 2)
        library.advanceNewEpisodeReferenceDate()
        _ = library.newEpisodeCount(for: subscription)
        _ = library.latestReleasedEpisodeDate(forPodcastID: show.feedURL)

        #expect(library.syncedStoreSelfSaveCount == savesBeforeReads)
        #expect(!fixture.context.hasChanges)
    }

    // MARK: - Fixtures

    private struct ShowFixture {
        let name: String
        let subscribedAt: Date
        let episodes: [EpisodeFixture]

        var feedURL: String {
            "https://example.com/\(name).xml"
        }

        var title: String {
            "Show \(name)"
        }
    }

    private struct EpisodeFixture {
        let id: String
        let publishedAt: Date?
        var duration: TimeInterval? = 600
        var progress: ProgressFixture?
    }

    private struct ProgressFixture {
        let position: TimeInterval
        let duration: TimeInterval?
        var isPlayed = false
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let cache: SQLiteLocalLibraryCacheStore
        let clock: TestClock
        let library: LibraryStore
        let subscriptionsByFeedURL: [String: SubscriptionRecord]

        func subscription(for show: ShowFixture) throws -> SubscriptionRecord {
            try #require(subscriptionsByFeedURL[show.feedURL])
        }
    }

    private func at(days: Double) -> Date {
        Self.start.addingTimeInterval(days * Self.day)
    }

    /// Loads the shows into a fresh in-memory library whose clock reads
    /// `start`. Progress rows carry a fixed stamp before `start` so later
    /// edits in a test always move the synced-reload probe.
    private func makeFixture(shows: [ShowFixture]) async throws -> Fixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        var subscriptionsByFeedURL: [String: SubscriptionRecord] = [:]
        for show in shows {
            if !show.episodes.isEmpty {
                try await cache.upsertCache(from: makeFeedSnapshot(for: show), refreshedAt: Self.start)
            }
            let subscription = SubscriptionRecord(
                feedURL: show.feedURL,
                title: show.title,
                subscribedAt: show.subscribedAt
            )
            context.insert(subscription)
            subscriptionsByFeedURL[show.feedURL] = subscription
            for episode in show.episodes {
                guard let progress = episode.progress else {
                    continue
                }
                context.insert(EpisodeProgressRecord(
                    episodeID: episode.id,
                    podcastID: show.feedURL,
                    position: progress.position,
                    duration: progress.duration,
                    isPlayed: progress.isPlayed,
                    updatedAt: Self.start.addingTimeInterval(-60 * 60)
                ))
            }
        }
        try context.save()
        let clock = TestClock(now: Self.start)
        let library = LibraryStore(localCache: cache, now: { clock.now })
        #expect(await library.load(modelContext: context))
        return Fixture(
            container: container,
            context: context,
            cache: cache,
            clock: clock,
            library: library,
            subscriptionsByFeedURL: subscriptionsByFeedURL
        )
    }

    private func makeFeedSnapshot(for show: ShowFixture) throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: show.feedURL))
        let podcast = Podcast(
            id: PodcastID(rawValue: show.feedURL),
            feedURL: feedURL,
            title: show.title
        )
        return FeedSnapshot(
            podcast: podcast,
            episodes: show.episodes.map { fixture in
                Episode(
                    id: EpisodeID(rawValue: fixture.id),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: "Episode \(fixture.id)",
                    publishedAt: fixture.publishedAt,
                    duration: fixture.duration,
                    audioURL: URL(string: "https://example.com/\(fixture.id).mp3"),
                    guid: fixture.id
                )
            }
        )
    }

    /// The badge rule restated over the raw fixture, independently of the
    /// store's index walk and progress summary.
    private func oracleCount(for show: ShowFixture, asOf: Date) -> Int {
        let windowStart = asOf.addingTimeInterval(-30 * Self.day)
        return show.episodes.filter { episode in
            guard let publishedAt = episode.publishedAt,
                  publishedAt >= show.subscribedAt,
                  publishedAt >= windowStart,
                  publishedAt <= asOf
            else {
                return false
            }
            guard let progress = episode.progress else {
                return true
            }
            if progress.isPlayed {
                return false
            }
            guard let duration = progress.duration ?? episode.duration,
                  duration > 0,
                  progress.position > 0
            else {
                return true
            }
            // Completed once less than a minute (or half the episode) remains.
            return duration - min(progress.position, duration) >= min(60, duration / 2)
        }.count
    }
}

@MainActor
private final class TestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
