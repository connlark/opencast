import Foundation
import OpenCastCore
import os
import Testing
@testable import OpenCast

@MainActor
@Suite("Publisher chapters store")
struct PublisherChaptersStoreTests {
    private static let feedURL = "https://example.com/chaptered.xml"
    private static let episodeID = "chaptered-episode"
    private static let documentURL = "https://example.com/chapters/episode.json"
    private static let movedDocumentURL = "https://example.com/chapters/episode-v2.json"
    private static let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)
    private static let document = Data(
        #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Opening"},{"startTime":4,"title":"Interview"}]}"#.utf8
    )
    private static let documentChapters = [
        EpisodeChapter(id: 0, title: "Opening", startTime: 0),
        EpisodeChapter(id: 1, title: "Interview", startTime: 4),
    ]
    private static let staleChapters = [EpisodeChapter(id: 0, title: "Earlier Cut", startTime: 0)]

    @Test("A fresh entry for the declared URL resolves with no request")
    func freshEntryMakesNoRequest() async throws {
        let fixture = try await makeFixture()
        try await fixture.seed(chapters: Self.documentChapters, fetchedAt: Self.referenceNow.addingTimeInterval(-24 * 60 * 60))

        let resolution = await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL)

        #expect(resolution == .chapters(Self.documentChapters))
        #expect(fixture.client.requestCount == 0)
    }

    @Test("An expired entry refetches and overwrites its fetch date")
    func expiredEntryRefetches() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])
        try await fixture.seed(
            chapters: Self.staleChapters,
            fetchedAt: Self.referenceNow.addingTimeInterval(-PublisherChaptersStore.freshnessInterval - 1)
        )

        let resolution = await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL)

        #expect(resolution == .chapters(Self.documentChapters))
        #expect(fixture.client.requestCount == 1)
        let stored = try #require(await fixture.store.cachedEntry(episodeID: Self.episodeID))
        #expect(stored == PublisherChaptersCacheEntry(
            sourceURL: Self.documentURL,
            chapters: Self.documentChapters,
            fetchedAt: Self.referenceNow
        ))
    }

    @Test("A changed document URL refetches and stores the new URL")
    func changedURLRefetches() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])
        try await fixture.seed(chapters: Self.staleChapters, fetchedAt: Self.referenceNow)
        try await fixture.declare(Self.movedDocumentURL)

        let resolution = await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.movedDocumentURL)

        #expect(resolution == .chapters(Self.documentChapters))
        #expect(fixture.client.requests.map(\.url?.absoluteString) == [Self.movedDocumentURL])
        let stored = try #require(await fixture.store.cachedEntry(episodeID: Self.episodeID))
        #expect(stored.sourceURL == Self.movedDocumentURL)
        #expect(stored.chapters == Self.documentChapters)
    }

    @Test("A 404 with nothing cached resolves unavailable, stores nothing, and backs off")
    func notFoundBacksOff() async throws {
        let fixture = try await makeFixture(responses: [.body(Data(), statusCode: 404), .body(Self.document)])

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .unavailable)
        #expect(await fixture.store.cachedEntry(episodeID: Self.episodeID) == nil)
        #expect(await !fixture.store.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.documentURL))

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .unavailable)
        #expect(fixture.client.requestCount == 1)

        fixture.advanceClock(by: PublisherChaptersStore.failureBackoff + 1)
        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .chapters(Self.documentChapters))
        #expect(fixture.client.requestCount == 2)
    }

    @Test("An oversized document resolves unavailable and stores nothing")
    func oversizedDocumentStoresNothing() async throws {
        let fixture = try await makeFixture(responses: [.oversized])

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .unavailable)
        #expect(fixture.client.requestCount == 1)
        #expect(await fixture.store.cachedEntry(episodeID: Self.episodeID) == nil)
    }

    @Test("A malformed document resolves unavailable and stores nothing", arguments: [
        "not json",
        #"{"chapters":{"startTime":0,"title":"Opening"}}"#,
        #"[{"startTime":0,"title":"Opening"}]"#,
    ])
    func malformedDocumentStoresNothing(body: String) async throws {
        let fixture = try await makeFixture(responses: [.body(Data(body.utf8))])

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .unavailable)
        #expect(fixture.client.requestCount == 1)
        #expect(await fixture.store.cachedEntry(episodeID: Self.episodeID) == nil)
    }

    @Test("An expired entry whose refetch fails keeps serving, untouched")
    func failedRefetchServesStaleEntry() async throws {
        let fixture = try await makeFixture(responses: [.transportFailure(.notConnectedToInternet)])
        let staleFetchedAt = Self.referenceNow.addingTimeInterval(-PublisherChaptersStore.freshnessInterval - 1)
        try await fixture.seed(chapters: Self.staleChapters, fetchedAt: staleFetchedAt)

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .chapters(Self.staleChapters))
        #expect(fixture.client.requestCount == 1)
        #expect(await fixture.store.cachedEntry(episodeID: Self.episodeID) == PublisherChaptersCacheEntry(
            sourceURL: Self.documentURL,
            chapters: Self.staleChapters,
            fetchedAt: staleFetchedAt
        ))

        // Inside the backoff the stale entry still answers, with no request.
        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .chapters(Self.staleChapters))
        #expect(fixture.client.requestCount == 1)
    }

    @Test("A stored empty entry resolves as an empty document with no request")
    func storedEmptyEntryIsKnownEmpty() async throws {
        let fixture = try await makeFixture()
        try await fixture.seed(chapters: [], fetchedAt: Self.referenceNow)

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .documentEmpty)
        #expect(fixture.client.requestCount == 0)
        #expect(await fixture.store.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.documentURL))
        #expect(await !fixture.store.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.movedDocumentURL))
    }

    @Test("A document with no usable chapter is stored and resolves as empty")
    func emptyDocumentIsStored() async throws {
        let placeholder = Data(#"{"version":"1.2.0","chapters":[{"startTime":0,"title":null}]}"#.utf8)
        let fixture = try await makeFixture(responses: [.body(placeholder)])

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .documentEmpty)
        #expect(await fixture.store.cachedEntry(episodeID: Self.episodeID) == PublisherChaptersCacheEntry(
            sourceURL: Self.documentURL,
            chapters: [],
            fetchedAt: Self.referenceNow
        ))
        #expect(await fixture.store.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.documentURL))
    }

    @Test("A cached entry with chapters is not known empty")
    func chapteredEntryIsNotKnownEmpty() async throws {
        let fixture = try await makeFixture()
        try await fixture.seed(chapters: Self.documentChapters, fetchedAt: Self.referenceNow)

        #expect(await !fixture.store.isDocumentKnownEmpty(episodeID: Self.episodeID, documentURL: Self.documentURL))
        #expect(fixture.client.requestCount == 0)
    }

    @Test("Concurrent callers share one request")
    func concurrentCallersShareOneRequest() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])
        await fixture.client.hold()
        let store = fixture.store

        let first = Task { await store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) }
        #expect(await waitUntil { fixture.client.requestCount == 1 })
        let second = Task { await store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) }
        await fixture.client.release()

        #expect(await first.value == .chapters(Self.documentChapters))
        #expect(await second.value == .chapters(Self.documentChapters))
        #expect(fixture.client.requestCount == 1)
    }

    @Test("A cancelled caller returns, and the shared fetch still stores its entry")
    func cancelledCallerLeavesFetchToFinish() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])
        await fixture.client.hold()
        let store = fixture.store

        let caller = Task { await store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) }
        #expect(await waitUntil { fixture.client.requestCount == 1 })
        caller.cancel()
        await fixture.client.release()

        #expect(await caller.value == .unavailable)
        await store.waitForFetch(episodeID: Self.episodeID)
        #expect(await store.cachedEntry(episodeID: Self.episodeID)?.chapters == Self.documentChapters)
        #expect(await store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) == .chapters(Self.documentChapters))
        #expect(fixture.client.requestCount == 1)
    }

    @Test("A fetch that lands after the declaration moved answers its callers and leaves the newer entry alone")
    func lateFetchKeepsNewerEntry() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])
        await fixture.client.hold()
        let store = fixture.store
        let newerEntry = PublisherChaptersCacheEntry(
            sourceURL: Self.movedDocumentURL,
            chapters: Self.staleChapters,
            fetchedAt: Self.referenceNow
        )

        let caller = Task { await store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) }
        #expect(await waitUntil { fixture.client.requestCount == 1 })
        try await fixture.declare(Self.movedDocumentURL)
        try await fixture.seed(chapters: newerEntry.chapters, fetchedAt: newerEntry.fetchedAt, sourceURL: newerEntry.sourceURL)
        await fixture.client.release()

        #expect(await caller.value == .chapters(Self.documentChapters))
        await store.waitForFetch(episodeID: Self.episodeID)
        #expect(await store.cachedEntry(episodeID: Self.episodeID) == newerEntry)
        #expect(fixture.client.requestCount == 1)
    }

    @Test("A fetch that lands after the declaration moved stores nothing when no entry is cached")
    func lateFetchStoresNothing() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])
        await fixture.client.hold()
        let store = fixture.store

        let caller = Task { await store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL) }
        #expect(await waitUntil { fixture.client.requestCount == 1 })
        try await fixture.declare(Self.movedDocumentURL)
        await fixture.client.release()

        #expect(await caller.value == .chapters(Self.documentChapters))
        await store.waitForFetch(episodeID: Self.episodeID)
        #expect(await store.cachedEntry(episodeID: Self.episodeID) == nil)
    }

    @Test("The request carries the timeout and the body cap")
    func requestCarriesTimeoutAndCap() async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])

        _ = await fixture.store.resolve(episodeID: Self.episodeID, documentURL: Self.documentURL)

        let request = try #require(fixture.client.requests.first)
        #expect(request.url?.absoluteString == Self.documentURL)
        #expect(request.timeoutInterval == 15)
        #expect(PublisherChaptersStore.requestTimeout == 15)
        #expect(fixture.client.maximumBodyByteCounts == [2 * 1024 * 1024])
        #expect(PublisherChaptersStore.documentByteLimit == 2 * 1024 * 1024)
    }

    @Test("A declared URL that is not a web URL makes no request", arguments: ["", "file:///private/var/chapters.json", "chapters.json"])
    func nonWebURLMakesNoRequest(documentURL: String) async throws {
        let fixture = try await makeFixture(responses: [.body(Self.document)])

        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: documentURL) == .unavailable)
        #expect(await fixture.store.resolve(episodeID: Self.episodeID, documentURL: documentURL) == .unavailable)
        #expect(fixture.client.requestCount == 0)
        #expect(await fixture.store.cachedEntry(episodeID: Self.episodeID) == nil)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let store: PublisherChaptersStore
        let cache: SQLiteLocalLibraryCacheStore
        let client: StubOpenCastHTTPClient
        let clock: OSAllocatedUnfairLock<Date>

        func seed(
            chapters: [EpisodeChapter],
            fetchedAt: Date,
            sourceURL: String = PublisherChaptersStoreTests.documentURL
        ) async throws {
            try await cache.storePublisherChapters(
                PublisherChaptersCacheEntry(sourceURL: sourceURL, chapters: chapters, fetchedAt: fetchedAt),
                episodeID: PublisherChaptersStoreTests.episodeID
            )
        }

        /// Moves the row's `chapters_url` the way a feed refresh does.
        func declare(_ documentURL: String) async throws {
            try await PublisherChaptersStoreTests.cacheEpisode(declaring: documentURL, in: cache)
        }

        func advanceClock(by interval: TimeInterval) {
            clock.withLock { $0 += interval }
        }
    }

    private func makeFixture(responses: [StubOpenCastHTTPClient.Response] = []) async throws -> Fixture {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await Self.cacheEpisode(declaring: Self.documentURL, in: cache)
        let client = StubOpenCastHTTPClient(responses: responses)
        let clock = OSAllocatedUnfairLock(initialState: Self.referenceNow)
        let store = PublisherChaptersStore(httpClient: client, localCache: cache) {
            clock.withLock { $0 }
        }
        return Fixture(store: store, cache: cache, client: client, clock: clock)
    }

    private static func cacheEpisode(declaring documentURL: String, in cache: SQLiteLocalLibraryCacheStore) async throws {
        let podcastID = PodcastID(rawValue: feedURL)
        let episode = Episode(
            id: EpisodeID(rawValue: episodeID),
            podcastID: podcastID,
            podcastTitle: "A Show",
            title: "Chaptered",
            audioURL: URL(string: "https://example.com/chaptered.mp3"),
            chaptersURL: URL(string: documentURL)
        )
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(id: podcastID, feedURL: URL(string: feedURL)!, title: "A Show"),
                episodes: [episode]
            ),
            refreshedAt: referenceNow
        )
    }
}
