import Foundation
import OpenCastCore
import SQLite3
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite(.serialized)
struct FeedRefreshOfflineTests {
    private let feedURL = URL(string: "https://example.com/offline.xml")!
    private let failingFeedURL = URL(string: "https://example.com/offline-503.xml")!
    private let hour: TimeInterval = 60 * 60
    private let offline = URLError(.notConnectedToInternet)
    private let serverError = OpenCastCoreError.unexpectedStatusCode(503)

    @Test(arguments: ["cached", "missing", "upgrade"])
    func unreachableAttemptsWriteNothingAndStayEligible(state: String) async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await seed(state, feedURLs: [feedURL], in: cache, refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let context = try subscribedContext(to: [feedURL])
        let service = PerURLFeedService(scripts: [feedURL: [
            .result(.failure(offline)),
            .result(.failure(URLError(.dataNotAllowed))),
            .result(.success(PreparedFeedOutcome(feed: try PreparedFeed(snapshot: snapshot(feedURL: feedURL))))),
        ]])
        let library = LibraryStore(feedService: service, localCache: reopened, now: { currentDate })
        #expect(await library.load(modelContext: context))

        for attempt in 1...2 {
            await automaticPass(state, library: library, context: context, now: currentDate)
            #expect(await service.requestCount(for: feedURL) == attempt)
            #expect(try await reopened.allRefreshLogs().isEmpty)
            #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString) == nil)
            #expect(library.automaticRetryAfterByFeedURL.isEmpty)
            #expect(library.lastRefreshWasOffline)
            #expect(library.state == .idle)
            #expect(library.lastErrorMessage == nil)
            if state != "cached" {
                #expect(library.feedURLStringsNeedingLocalCache == [feedURL.absoluteString])
            }
            if state != "missing" {
                #expect(library.episode(with: episodeID(for: feedURL)) != nil)
            }
        }

        await automaticPass(state, library: library, context: context, now: currentDate)
        #expect(await service.requestCount(for: feedURL) == 3)
        #expect(!library.lastRefreshWasOffline)
        let log = try #require(library.latestRefreshLog(feedURL: feedURL.absoluteString))
        #expect(log.errorMessage == nil)
        #expect(library.automaticRetryAfterByFeedURL.isEmpty)
        #expect(library.feedURLStringsNeedingLocalCache.isEmpty)
        #expect(library.episode(with: episodeID(for: feedURL)) != nil)
    }

    @Test(arguments: ["cached", "missing", "upgrade"])
    func mixedPassHoldsOnlyTheServerFailure(state: String) async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await seed(
            state,
            feedURLs: [feedURL, failingFeedURL],
            in: cache,
            refreshedAt: currentDate.addingTimeInterval(-2 * hour)
        )
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let context = try subscribedContext(to: [feedURL, failingFeedURL])
        let service = PerURLFeedService(scripts: [
            feedURL: [.result(.failure(offline))],
            failingFeedURL: [.result(.failure(serverError))],
        ])
        let library = LibraryStore(feedService: service, localCache: reopened, now: { currentDate })
        #expect(await library.load(modelContext: context))

        await automaticPass(state, library: library, context: context, now: currentDate)

        #expect(await service.requestCount(for: feedURL) == 1)
        #expect(await service.requestCount(for: failingFeedURL) == 1)
        #expect(library.automaticRetryAfterByFeedURL == [failingFeedURL.absoluteString: currentDate.addingTimeInterval(hour)])
        #expect(library.latestRefreshLog(feedURL: failingFeedURL.absoluteString)?.errorMessage
            == serverError.localizedDescription)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString) == nil)
        #expect(try await reopened.allRefreshLogs().map(\.feedURL) == [failingFeedURL.absoluteString])
        #expect(library.lastRefreshWasOffline)
        #expect(library.state == .idle)
        #expect(library.lastErrorMessage == nil)
    }

    @Test func singleFeedRefreshOfflineKeepsTheEarlierHold() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let context = try subscribedContext(to: [feedURL])
        let service = PerURLFeedService(scripts: [feedURL: [
            .result(.failure(serverError)),
            .result(.failure(offline)),
        ]])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))
        await library.refreshAllIfStale(modelContext: context, now: currentDate)
        let deadline = currentDate.addingTimeInterval(hour)
        #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == deadline)
        #expect(!library.lastRefreshWasOffline)
        let logs = try await cache.allRefreshLogs()
        #expect(logs.count == 1)

        currentDate += 10
        await library.refresh(feedURL: feedURL.absoluteString, modelContext: context)

        #expect(await service.requestCount(for: feedURL) == 2)
        #expect(try await cache.allRefreshLogs() == logs)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage == serverError.localizedDescription)
        #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == deadline)
        #expect(library.refreshingFeedURLs.isEmpty)
        #expect(library.lastRefreshWasOffline)
        #expect(library.lastErrorMessage == nil)
    }

    @Test func idleConnectivityRecoveryClearsTheFlagAndOptionallyRefreshes() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let context = try subscribedContext(to: [feedURL])
        let service = PerURLFeedService(scripts: [feedURL: [
            .result(.failure(offline)),
            .result(.failure(offline)),
            .result(.success(PreparedFeedOutcome(feed: try PreparedFeed(snapshot: snapshot(feedURL: feedURL))))),
        ]])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))
        await library.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(library.lastRefreshWasOffline)

        await library.recoverConnectivity(refreshesStaleFeeds: false, modelContext: context, now: currentDate)

        #expect(!library.lastRefreshWasOffline)
        #expect(await service.requestCount(for: feedURL) == 1)
        #expect(try await cache.allRefreshLogs().isEmpty)

        await library.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(library.lastRefreshWasOffline)

        await library.recoverConnectivity(refreshesStaleFeeds: true, modelContext: context, now: currentDate)

        #expect(!library.lastRefreshWasOffline)
        #expect(await service.requestCount(for: feedURL) == 3)
        let log = try #require(library.latestRefreshLog(feedURL: feedURL.absoluteString))
        #expect(log.errorMessage == nil)
        #expect(library.automaticRetryAfterByFeedURL.isEmpty)
        #expect(library.state == .idle)
    }

    @Test(arguments: [false, true])
    func recoveryBeforeOfflineResultRunsOnceTheLibraryIsIdle(singleFeed: Bool) async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let context = try subscribedContext(to: [feedURL])
        let gate = AsyncTestGate()
        let service = PerURLFeedService(scripts: [feedURL: [
            .gated(gate, .failure(offline)),
            .result(.success(PreparedFeedOutcome(feed: try PreparedFeed(snapshot: snapshot(feedURL: feedURL))))),
        ]])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))

        let pass = Task {
            if singleFeed {
                await library.refresh(feedURL: feedURL.absoluteString, modelContext: context)
            } else {
                await library.refreshAllIfStale(modelContext: context, now: currentDate)
            }
        }
        #expect(await waitUntil { !library.refreshingFeedURLs.isEmpty })
        #expect(!library.lastRefreshWasOffline)
        let decision = ConnectivityRecoveryPolicy(
            previousPathWasSatisfied: false,
            pathIsSatisfied: true,
            lastRefreshWasOffline: library.lastRefreshWasOffline
        ).decision
        #expect(decision == .clearMarkerAndRefresh)
        if decision == .clearMarkerAndRefresh {
            await library.recoverConnectivity(refreshesStaleFeeds: true, modelContext: context, now: currentDate)
        }
        await gate.release()
        await pass.value
        await library.waitForConnectivityRecoveryForTesting()

        #expect(!library.lastRefreshWasOffline)
        #expect(library.state == .idle)
        #expect(await service.requestCount(for: feedURL) == 2)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage == nil)
        #expect(library.automaticRetryAfterByFeedURL.isEmpty)
        #expect(library.refreshingFeedURLs.isEmpty)
    }

    @Test func deferredRecoveryRechecksEligibilityAfterTheBusyPass() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let context = try subscribedContext(to: [feedURL])
        let gate = AsyncTestGate()
        let service = PerURLFeedService(scripts: [feedURL: [
            .gated(gate, .failure(offline)),
            .result(.success(PreparedFeedOutcome(feed: try PreparedFeed(snapshot: snapshot(feedURL: feedURL))))),
        ]])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))
        let pass = Task {
            await library.refreshAllIfStale(modelContext: context, now: currentDate)
        }
        #expect(await waitUntil { library.state == .refreshing })
        var allowsRefresh = true
        var eligibilityChecks = 0
        await library.recoverConnectivity(
            refreshesStaleFeeds: true,
            modelContext: context,
            now: currentDate,
            canRefresh: {
                eligibilityChecks += 1
                return allowsRefresh
            }
        )
        #expect(eligibilityChecks == 0)
        // A subsequent marker-only request must preserve the refresh gate.
        await library.recoverConnectivity(refreshesStaleFeeds: false, modelContext: context, now: currentDate)
        allowsRefresh = false
        await gate.release()
        await pass.value
        await library.waitForConnectivityRecoveryForTesting()

        #expect(eligibilityChecks == 1)
        #expect(await service.requestCount(for: feedURL) == 1)
        #expect(!library.lastRefreshWasOffline)
        #expect(try await cache.allRefreshLogs().isEmpty)
        #expect(library.state == .idle)

        // Once the presentation deferral ends, the feed is still eligible.
        allowsRefresh = true
        await library.recoverConnectivity(
            refreshesStaleFeeds: true,
            modelContext: context,
            now: currentDate,
            canRefresh: { allowsRefresh }
        )
        #expect(await service.requestCount(for: feedURL) == 2)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString) != nil)
    }

    @Test func cancellingRecoveryPreventsARefreshWhenTheBusyPassEnds() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        let context = try subscribedContext(to: [feedURL])
        let gate = AsyncTestGate()
        let service = PerURLFeedService(scripts: [feedURL: [
            .gated(gate, .failure(offline)),
            .result(.success(PreparedFeedOutcome(feed: try PreparedFeed(snapshot: snapshot(feedURL: feedURL))))),
        ]])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))
        let pass = Task {
            await library.refreshAllIfStale(modelContext: context, now: currentDate)
        }
        #expect(await waitUntil { library.state == .refreshing })
        await library.recoverConnectivity(refreshesStaleFeeds: true, modelContext: context, now: currentDate)
        library.cancelConnectivityRecovery()
        await gate.release()
        await pass.value
        await library.waitForConnectivityRecoveryForTesting()

        #expect(await service.requestCount(for: feedURL) == 1)
        #expect(library.lastRefreshWasOffline)
        #expect(try await cache.allRefreshLogs().isEmpty)
        #expect(library.state == .idle)

        // Cancellation must not prevent recovery on the next activation.
        await library.recoverConnectivity(refreshesStaleFeeds: true, modelContext: context, now: currentDate)
        #expect(await service.requestCount(for: feedURL) == 2)
        #expect(!library.lastRefreshWasOffline)
    }

    @Test func everyReachableOutcomeClearsTheFlag() async throws {
        let databaseURL = temporaryDatabase()
        defer { removeDatabase(databaseURL) }
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: currentDate.addingTimeInterval(-2 * hour))
        var changed = snapshot(feedURL: feedURL)
        changed.episodes[0].title = "Updated episode"
        let changedOutcome = PreparedFeedOutcome(feed: try PreparedFeed(snapshot: changed))
        let service = PerURLFeedService(scripts: [feedURL: [
            .result(.failure(offline)),
            .result(.success(PreparedFeedOutcome(feed: nil))),
            .result(.failure(offline)),
            .result(.success(changedOutcome)),
            .result(.failure(offline)),
            .result(.success(changedOutcome)),
        ]])
        let context = try subscribedContext(to: [feedURL])
        let library = LibraryStore(feedService: service, localCache: cache, now: { currentDate })
        #expect(await library.load(modelContext: context))

        await library.refreshAll(modelContext: context)
        #expect(library.lastRefreshWasOffline)
        currentDate += 10
        await library.refreshAll(modelContext: context)
        #expect(!library.lastRefreshWasOffline)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage == nil)

        currentDate += 10
        await library.refreshAll(modelContext: context)
        #expect(library.lastRefreshWasOffline)
        try await rawSQL("""
            CREATE TRIGGER fail_offline_import BEFORE INSERT ON episode_cache
            BEGIN SELECT RAISE(ABORT,'injected cache write failure'); END;
            """, in: cache)
        currentDate += 10
        await library.refreshAll(modelContext: context)
        #expect(!library.lastRefreshWasOffline)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage?
            .contains("injected cache write failure") == true)
        #expect(library.automaticRetryAfterByFeedURL[feedURL.absoluteString] == currentDate.addingTimeInterval(hour))

        try await rawSQL("DROP TRIGGER fail_offline_import", in: cache)
        currentDate += 10
        await library.refreshAll(modelContext: context)
        #expect(library.lastRefreshWasOffline)
        currentDate += 10
        await library.refreshAll(modelContext: context)
        #expect(!library.lastRefreshWasOffline)
        #expect(library.latestRefreshLog(feedURL: feedURL.absoluteString)?.errorMessage == nil)
        #expect(library.episode(with: episodeID(for: feedURL))?.title == "Updated episode")
        #expect(await service.requestCount(for: feedURL) == 6)
    }

    private func automaticPass(_ state: String, library: LibraryStore, context: ModelContext, now: Date) async {
        if state == "cached" {
            await library.refreshAllIfStale(modelContext: context, now: now)
        } else {
            #expect(await library.refreshFeedsNeedingLocalCache(modelContext: context, now: now))
        }
    }

    private func seed(
        _ state: String,
        feedURLs: [URL],
        in cache: SQLiteLocalLibraryCacheStore,
        refreshedAt: Date
    ) async throws {
        if state == "missing" {
            _ = try await cache.loadLibrary(activePodcastIDs: [])
        } else {
            for feedURL in feedURLs {
                try await cache.upsertCache(from: snapshot(feedURL: feedURL), refreshedAt: refreshedAt)
            }
        }
        if state == "upgrade" {
            try await rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", in: cache)
        }
    }

    private func subscribedContext(to feedURLs: [URL]) throws -> ModelContext {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for feedURL in feedURLs {
            context.insert(SubscriptionRecord(feedURL: feedURL.absoluteString, title: "Offline Show"))
        }
        try context.save()
        return context
    }

    private func episodeID(for feedURL: URL) -> String {
        "episode-\(feedURL.lastPathComponent)"
    }

    private func snapshot(feedURL: URL) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL.absoluteString)
        return FeedSnapshot(
            podcast: Podcast(id: podcastID, feedURL: feedURL, title: "Offline Show"),
            episodes: [Episode(
                id: EpisodeID(rawValue: episodeID(for: feedURL)), podcastID: podcastID,
                podcastTitle: "Offline Show", title: "Episode", showNotesHTML: "Notes",
                audioURL: URL(string: "https://example.com/\(feedURL.lastPathComponent).mp3"),
                guid: "guid-\(feedURL.lastPathComponent)"
            )]
        )
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "feed-offline-\(UUID()).sqlite")
    }

    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func rawSQL(_ sql: String, in cache: SQLiteLocalLibraryCacheStore) async throws {
        try await cache.inspectConnectionForTesting { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "OfflineTestSQLite", code: Int(sqlite3_errcode(db)),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }
}

/// Scripts results per feed URL: the fetcher fans feeds out concurrently, so
/// a single shared queue would hand one feed another feed's result.
private actor PerURLFeedService: FeedService {
    enum Script: Sendable {
        case result(Result<PreparedFeedOutcome, any Error>)
        case gated(AsyncTestGate, Result<PreparedFeedOutcome, any Error>)
    }

    private var scriptsByURL: [String: [Script]]
    private var requestCountsByURL: [String: Int] = [:]

    init(scripts: [URL: [Script]]) {
        scriptsByURL = Dictionary(uniqueKeysWithValues: scripts.map { ($0.key.absoluteString, $0.value) })
    }

    func requestCount(for url: URL) -> Int {
        requestCountsByURL[url.absoluteString, default: 0]
    }

    func prepareFeed(at url: URL, validators _: FeedValidators?) async throws -> PreparedFeedOutcome {
        let key = url.absoluteString
        requestCountsByURL[key, default: 0] += 1
        guard var scripts = scriptsByURL[key], !scripts.isEmpty else {
            throw OpenCastCoreError.unexpectedStatusCode(599)
        }
        let script = scripts.removeFirst()
        scriptsByURL[key] = scripts
        switch script {
        case .result(let result):
            return try result.get()
        case .gated(let gate, let result):
            await gate.wait()
            return try result.get()
        }
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let outcome = try await prepareFeed(at: url, validators: nil)
        guard let feed = outcome.feed else { throw OpenCastCoreError.invalidHTTPResponse }
        return try feed.materialized()
    }
}
