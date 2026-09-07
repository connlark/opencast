import Foundation
import OpenCastCore
import SQLite3
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite(.serialized)
struct FeedRetryPolicyTests {
    private let feedURL = URL(string: "https://example.com/retry-policy.xml")!
    private let hour: TimeInterval = 60 * 60

    @Test(arguments: ["cached", "missing", "upgrade"])
    func ordinaryFailuresRetryHourlyAcrossRelaunchAndRecover(state: String) async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let original = snapshot()
        if state != "missing" {
            try await cache.upsertCache(from: original, refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        } else {
            _ = try await cache.loadLibrary(activePodcastIDs: [])
        }
        if state == "upgrade" {
            try await rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", in: cache)
        }
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: feedURL.absoluteString, title: "Retry Show"))
        let progress = EpisodeProgressRecord(
            episodeID: "retry-episode", podcastID: feedURL.absoluteString, position: 45, duration: 120
        )
        context.insert(progress)
        try context.save()
        let failures: [any Error] = [
            URLError(.notConnectedToInternet), URLError(.networkConnectionLost),
            URLError(.timedOut), URLError(.cannotConnectToHost),
            OpenCastCoreError.unexpectedStatusCode(503),
            OpenCastCoreError.incompleteFeed(reason: .fieldLimit),
        ]
        let service = RetrySequenceFeedService(
            results: failures.map { .failure($0) }
                + [.success(PreparedFeedOutcome(feed: try PreparedFeed(snapshot: original)))]
        )

        for attempt in failures.indices {
            let library = LibraryStore(
                feedService: service,
                localCache: SQLiteLocalLibraryCacheStore(databaseURL: databaseURL),
                now: { currentDate }
            )
            #expect(await library.load(modelContext: context))
            if state == "cached" {
                await library.refreshAllIfStale(modelContext: context, now: currentDate)
            } else {
                #expect(await library.refreshFeedsNeedingLocalCache(modelContext: context, now: currentDate))
            }
            #expect(await service.requestCount == attempt + 1)
            #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == currentDate.addingTimeInterval(hour))
            #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage
                == failures[attempt].localizedDescription)
            if state != "cached" {
                #expect(library.feedURLStringsNeedingLocalCache == [feedURL.absoluteString])
            }
            #expect(progress.position == 45)

            currentDate += hour - 1
            let relaunched = LibraryStore(
                feedService: service,
                localCache: SQLiteLocalLibraryCacheStore(databaseURL: databaseURL),
                now: { currentDate }
            )
            #expect(await relaunched.load(modelContext: context))
            await relaunched.refreshAllIfStale(modelContext: context, now: currentDate)
            #expect(await relaunched.refreshFeedsNeedingLocalCache(modelContext: context, now: currentDate) == false)
            #expect(await service.requestCount == attempt + 1)
            currentDate += 1
        }

        let recovered = LibraryStore(
            feedService: service,
            localCache: SQLiteLocalLibraryCacheStore(databaseURL: databaseURL),
            now: { currentDate }
        )
        #expect(await recovered.load(modelContext: context))
        await recovered.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(await service.requestCount == failures.count + 1)
        #expect(recovered.automaticRetryAfterByFeedURL.isEmpty)
        #expect(recovered.feedURLStringsNeedingLocalCache.isEmpty)
        #expect(recovered.episode(with: "retry-episode") != nil)
        #expect(progress.position == 45)
    }

    @Test func manualFailureBypassesDeadlineAndCancellationDoesNotChangeIt() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let original = snapshot()
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: original, refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let validators = FeedValidators(entityTag: "still-current", bodyHash: "complete")
        try await cache.updateFeedValidators(validators, forPodcastID: feedURL.absoluteString)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: feedURL.absoluteString, title: "Retry Show"))
        try context.save()
        let service = RetrySequenceFeedService(results: [
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet)),
            .failure(CancellationError()),
            .success(PreparedFeedOutcome(feed: nil, validators: validators)),
        ])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))
        await library.refreshAllIfStale(modelContext: context, now: currentDate)
        currentDate += 10
        await library.refresh(feedURL: feedURL.absoluteString, modelContext: context)
        let deadline = currentDate.addingTimeInterval(hour)
        #expect(await service.requestCount == 2)
        #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == deadline)
        let logCount = try await cache.allRefreshLogs().count
        currentDate += 10
        await library.refresh(feedURL: feedURL.absoluteString, modelContext: context)
        #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == deadline)
        #expect(try await cache.allRefreshLogs().count == logCount)
        await library.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(await service.requestCount == 3)
        await library.refreshAll(modelContext: context)
        #expect(await service.requestCount == 4)
        #expect(library.automaticRetryAfterByFeedURL.isEmpty)
        #expect(try await cache.feedValidators(forPodcastID: feedURL.absoluteString) == validators)
    }

    @Test func failedImportsRetryHourlyWithoutChangingTheCatalog() async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        var changed = snapshot()
        changed.episodes[0].title = "Updated episode"
        let outcome = PreparedFeedOutcome(feed: try PreparedFeed(snapshot: changed))
        let service = RetrySequenceFeedService(results: Array(repeating: .success(outcome), count: 4))
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: feedURL.absoluteString, title: "Retry Show"))
        try context.save()
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))
        try await rawSQL("""
            CREATE TRIGGER fail_retry_import BEFORE INSERT ON episode_cache
            BEGIN SELECT RAISE(ABORT,'injected cache write failure'); END;
            """, in: cache)
        for attempt in 1...3 {
            await library.refreshAllIfStale(modelContext: context, now: currentDate)
            #expect(await service.requestCount == attempt)
            #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == currentDate.addingTimeInterval(hour))
            #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage?
                .contains("injected cache write failure") == true)
            #expect(try await cache.episodeDetail(episodeID: "retry-episode")?.listItem.title == "Episode")
            currentDate += hour
        }
        try await rawSQL("DROP TRIGGER fail_retry_import", in: cache)
        await library.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(await service.requestCount == 4)
        #expect(library.automaticRetryAfterByFeedURL.isEmpty)
        #expect(try await cache.episodeDetail(episodeID: "retry-episode")?.listItem.title == "Updated episode")
    }

    @Test func ordinaryFailuresDoNotInflateOrShortenPartialBackoff() async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        var partial = try PreparedFeed(snapshot: snapshot())
        partial.completeness = .partial(.interruptedTransfer("Connection lost"))
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: partial, refreshedAt: first)
        let second = first.addingTimeInterval(hour)
        try await cache.upsertCache(from: partial, refreshedAt: second)
        let partialDeadline = second.addingTimeInterval(2 * hour)
        // A manually forced failed transfer must not erase the partial delay.
        try await cache.recordFeedRetryFailure(forPodcastID: feedURL.absoluteString, attemptedAt: second.addingTimeInterval(10))
        var loaded = try await cache.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.automaticRetryAfterByFeedURL[feedURL.absoluteString] == partialDeadline)
        // Once that delay expires, ordinary failures stay hourly, even after relaunch.
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        for index in 0..<4 {
            let attemptedAt = partialDeadline.addingTimeInterval(TimeInterval(index) * hour)
            try await reopened.recordFeedRetryFailure(forPodcastID: feedURL.absoluteString, attemptedAt: attemptedAt)
            loaded = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
            #expect(loaded.automaticRetryAfterByFeedURL[feedURL.absoluteString] == attemptedAt.addingTimeInterval(hour))
            #expect(loaded.incompleteFeeds[feedURL.absoluteString] == partial.completeness.reason)
        }
        let third = partialDeadline.addingTimeInterval(4 * hour)
        try await reopened.upsertCache(from: partial, refreshedAt: third)
        loaded = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.automaticRetryAfterByFeedURL[feedURL.absoluteString] == third.addingTimeInterval(4 * hour))
        #expect(try await reopened.feedValidators(forPodcastID: feedURL.absoluteString) == nil)
        try await reopened.upsertCache(from: snapshot(), refreshedAt: third.addingTimeInterval(10))
        loaded = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.automaticRetryAfterByFeedURL.isEmpty)
        #expect(loaded.incompleteFeeds.isEmpty)
    }

    @Test func retryPolicyUpgradeClearsOldPenaltiesOnceAndPreservesRecovery() async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var partial = try PreparedFeed(snapshot: snapshot())
        partial.completeness = .partial(.fieldLimit)
        try await cache.upsertCache(from: partial, refreshedAt: date)
        var complete = snapshot()
        complete.podcast.id = PodcastID(rawValue: "https://example.com/complete.xml")
        complete.podcast.feedURL = URL(string: complete.podcast.id.rawValue)!
        complete.episodes = []
        try await cache.upsertCache(from: complete, refreshedAt: date)
        let validators = FeedValidators(entityTag: "preserve", bodyHash: "preserve")
        try await cache.updateFeedValidators(validators, forPodcastID: complete.podcast.id.rawValue)
        try await rawSQL("""
            DELETE FROM local_cache_meta WHERE key='feed_retry_policy_version';
            UPDATE feed_load_state SET consecutive_partial_attempts=6,
                automatic_retry_after=9999999999, requires_refresh=1;
            """, in: cache)
        let upgraded = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let active = Set([feedURL.absoluteString, complete.podcast.id.rawValue])
        let loaded = try await upgraded.loadLibrary(activePodcastIDs: active)
        #expect(loaded.automaticRetryAfterByFeedURL.isEmpty)
        #expect(loaded.processingRefreshPodcastIDs == active)
        #expect(loaded.incompleteFeeds[feedURL.absoluteString] == .fieldLimit)
        #expect(loaded.episodes.map(\.episodeID) == ["retry-episode"])
        #expect(try await upgraded.episodeDetail(episodeID: "retry-episode")?.showNotesHTML == "Complete notes")
        #expect(try await upgraded.feedValidators(forPodcastID: complete.podcast.id.rawValue) == validators)
        try await upgraded.upsertCache(from: partial, refreshedAt: date)
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let next = try await reopened.loadLibrary(activePodcastIDs: active)
        #expect(next.automaticRetryAfterByFeedURL[feedURL.absoluteString] == date.addingTimeInterval(hour))
        #expect(next.processingRefreshPodcastIDs == [complete.podcast.id.rawValue])
    }

    @Test func cancelledFailureRecordingLeavesTheDurableDeadlineUntouched() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(), refreshedAt: date)
        try await cache.recordFeedRetryFailure(forPodcastID: feedURL.absoluteString, attemptedAt: date)
        let recording = Task { @MainActor in
            try await cache.recordFeedRetryFailure(
                forPodcastID: feedURL.absoluteString,
                attemptedAt: date.addingTimeInterval(10 * hour)
            )
        }
        recording.cancel()
        await #expect(throws: CancellationError.self) { try await recording.value }
        let loaded = try await cache.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.automaticRetryAfterByFeedURL[feedURL.absoluteString] == date.addingTimeInterval(hour))
    }

    @Test func interruptedDownloadExplanationSurvivesRefreshLogging() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: snapshot(), refreshedAt: .now)
        let error = OpenCastCoreError.incompleteFeed(reason: .interruptedTransfer("Connection lost"))
        let service = RetrySequenceFeedService(results: [.failure(error)])
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: feedURL.absoluteString, title: "Retry Show"))
        try context.save()
        let library = LibraryStore(feedService: service, localCache: cache)
        #expect(await library.load(modelContext: context))
        await library.refresh(feedURL: feedURL.absoluteString, modelContext: context)
        let message = try #require(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage)
        #expect(message.contains("transfer was interrupted"))
        #expect(message.contains("Connection lost"))
        #expect(!message.contains("XML is invalid"))
        #expect(library.episode(with: "retry-episode") != nil)
    }

    private func snapshot() -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL.absoluteString)
        return FeedSnapshot(
            podcast: Podcast(id: podcastID, feedURL: feedURL, title: "Retry Show"),
            episodes: [Episode(
                id: EpisodeID(rawValue: "retry-episode"), podcastID: podcastID,
                podcastTitle: "Retry Show", title: "Episode", showNotesHTML: "Complete notes",
                audioURL: URL(string: "https://example.com/episode.mp3"), guid: "retry-guid"
            )]
        )
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "feed-retry-\(UUID()).sqlite")
    }

    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func rawSQL(_ sql: String, in cache: SQLiteLocalLibraryCacheStore) async throws {
        try await cache.inspectConnectionForTesting { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "RetryPolicyTestSQLite", code: Int(sqlite3_errcode(db)),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

}

private actor RetrySequenceFeedService: FeedService {
    private var results: [Result<PreparedFeedOutcome, any Error>]
    private(set) var requestCount = 0

    init(results: [Result<PreparedFeedOutcome, any Error>]) { self.results = results }

    func prepareFeed(at _: URL, validators _: FeedValidators?) async throws -> PreparedFeedOutcome {
        requestCount += 1
        guard !results.isEmpty else { throw URLError(.badServerResponse) }
        return try results.removeFirst().get()
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let outcome = try await prepareFeed(at: url, validators: nil)
        guard let feed = outcome.feed else { throw OpenCastCoreError.invalidHTTPResponse }
        return try feed.materialized()
    }
}
