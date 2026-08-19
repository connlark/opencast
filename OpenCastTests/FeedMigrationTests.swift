import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Moved-feed migration")
struct FeedMigrationTests {
    static let oldFeedURL = "https://example.com/old.xml"
    static let newFeedURL = "https://example.net/new.xml"
    static let dateOne = Date(timeIntervalSince1970: 1_700_000_100)

    @Test("A declared itunes:new-feed-url migrates the subscription and carries progress")
    func newFeedURLDeclarationMigratesSubscription() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let oldSnapshotV1 = makeSnapshot(feedURL: Self.oldFeedURL, title: "Moving Show")
        var oldSnapshotV2 = oldSnapshotV1
        oldSnapshotV2.newFeedURL = URL(string: Self.newFeedURL)
        let newSnapshot = makeSnapshot(feedURL: Self.newFeedURL, title: "Moving Show")
        let service = OutcomeStubFeedService(outcomes: [
            Self.oldFeedURL: [
                FeedFetchOutcome(snapshot: oldSnapshotV1),
                FeedFetchOutcome(snapshot: oldSnapshotV2, newFeedURL: URL(string: Self.newFeedURL))
            ],
            Self.newFeedURL: [FeedFetchOutcome(snapshot: newSnapshot)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        try await store.subscribe(to: Self.oldFeedURL, modelContext: context)

        let oldEpisodeID = oldSnapshotV1.episodes[0].id.rawValue
        let newEpisodeID = newSnapshot.episodes[0].id.rawValue
        #expect(oldEpisodeID != newEpisodeID)
        context.insert(
            EpisodeProgressRecord(episodeID: oldEpisodeID, podcastID: Self.oldFeedURL, position: 240)
        )
        try context.save()

        await store.refresh(feedURL: Self.oldFeedURL, modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [Self.newFeedURL])

        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.map(\.episodeID) == [newEpisodeID])
        #expect(progress.first?.podcastID == Self.newFeedURL)

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(
            tombstones.contains { tombstone in
                tombstone.scope == SyncTombstoneScope.subscription.rawValue
                    && tombstone.feedURL == Self.oldFeedURL
            }
        )
        #expect(
            tombstones.contains { tombstone in
                tombstone.scope == SyncTombstoneScope.episodeProgress.rawValue
                    && tombstone.episodeID == oldEpisodeID
            }
        )

        #expect(Set(store.episodes.map(\.podcastID)) == Set([Self.newFeedURL]))
    }

    @Test("A migration collision keeps the largest valid intro and outro trims")
    func migrationCollisionMergesPlaybackSkips() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let newSnapshot = makeSnapshot(feedURL: Self.newFeedURL, title: "Moving Show")
        let service = OutcomeStubFeedService(outcomes: [
            Self.newFeedURL: [FeedFetchOutcome(snapshot: newSnapshot)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        context.insert(
            SubscriptionRecord(
                feedURL: Self.oldFeedURL,
                title: "Moving Show",
                skipIntroSeconds: 45,
                skipOutroSeconds: 10
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: Self.newFeedURL,
                title: "Moving Show",
                skipIntroSeconds: 30,
                skipOutroSeconds: 20
            )
        )
        try context.save()
        await store.load(modelContext: context)

        try await store.migrateSubscription(
            from: Self.oldFeedURL,
            toFeedURL: try #require(URL(string: Self.newFeedURL)),
            modelContext: context
        )

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let subscription = try #require(subscriptions.first)
        #expect(subscriptions.count == 1)
        #expect(subscription.feedURL == Self.newFeedURL)
        #expect(subscription.skipIntroSeconds == 45)
        #expect(subscription.skipOutroSeconds == 20)
        #expect(store.podcastPlaybackSkipSettings(forPodcastID: Self.newFeedURL) == PodcastPlaybackSkipSettings(
            skipIntroSeconds: 45,
            skipOutroSeconds: 20
        ))
    }

    @Test("Persistent redirect divergence suggests but never auto-migrates")
    func redirectDivergenceSuggestsWithoutMigrating() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let snapshot = makeSnapshot(feedURL: Self.oldFeedURL, title: "Redirected Show")
        let divergedURL = URL(string: "https://cdn.example.org/old.xml")!
        let service = OutcomeStubFeedService(outcomes: [
            Self.oldFeedURL: [
                FeedFetchOutcome(snapshot: snapshot),
                FeedFetchOutcome(snapshot: snapshot, finalURL: divergedURL),
                FeedFetchOutcome(snapshot: snapshot, finalURL: divergedURL),
                FeedFetchOutcome(snapshot: snapshot, finalURL: divergedURL)
            ]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        try await store.subscribe(to: Self.oldFeedURL, modelContext: context)

        await store.refresh(feedURL: Self.oldFeedURL, modelContext: context)
        await store.refresh(feedURL: Self.oldFeedURL, modelContext: context)
        #expect(store.suggestedFeedMigrationURLsByFeedURL[Self.oldFeedURL] == nil)

        await store.refresh(feedURL: Self.oldFeedURL, modelContext: context)
        #expect(store.suggestedFeedMigrationURLsByFeedURL[Self.oldFeedURL] == divergedURL)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [Self.oldFeedURL])
        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).isEmpty)
    }

    @Test("An http feed upgrades onto its https twin when the twin matches")
    func httpFeedUpgradesOntoMatchingHTTPSTwin() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let httpFeedURL = "http://example.com/insecure.xml"
        let httpsFeedURL = "https://example.com/insecure.xml"
        let httpSnapshot = makeSnapshot(feedURL: httpFeedURL, title: "Insecure Show")
        let httpsSnapshot = makeSnapshot(feedURL: httpsFeedURL, title: "Insecure Show")
        let service = OutcomeStubFeedService(outcomes: [
            httpFeedURL: [FeedFetchOutcome(snapshot: httpSnapshot)],
            httpsFeedURL: [FeedFetchOutcome(snapshot: httpsSnapshot)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        try await store.subscribe(to: httpFeedURL, modelContext: context)
        context.insert(
            EpisodeProgressRecord(
                episodeID: httpSnapshot.episodes[0].id.rawValue,
                podcastID: httpFeedURL,
                position: 90
            )
        )
        try context.save()

        await store.refresh(feedURL: httpFeedURL, modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [httpsFeedURL])
        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.map(\.episodeID) == [httpsSnapshot.episodes[0].id.rawValue])
    }

    @Test("A not-modified outcome records success and leaves the cache untouched")
    func notModifiedOutcomeRecordsSuccessAndLeavesCacheUntouched() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let snapshot = makeSnapshot(feedURL: Self.oldFeedURL, title: "Unchanged Show")
        let refreshedValidators = FeedValidators(entityTag: "\"tag-2\"", bodyHash: "hash-2")
        let service = OutcomeStubFeedService(outcomes: [
            Self.oldFeedURL: [
                FeedFetchOutcome(snapshot: snapshot),
                FeedFetchOutcome(snapshot: nil, validators: refreshedValidators)
            ]
        ])
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(feedService: service, localCache: cache)
        try await store.subscribe(to: Self.oldFeedURL, modelContext: context)
        let cachedAtAfterSubscribe = store.episodes.first?.cachedAt

        await store.refresh(feedURL: Self.oldFeedURL, modelContext: context)

        #expect(store.latestRefreshLogByFeedURL[Self.oldFeedURL]?.errorMessage == nil)
        #expect(store.latestRefreshLogByFeedURL[Self.oldFeedURL] != nil)
        #expect(store.episodes.count == 1)
        #expect(store.episodes.first?.cachedAt == cachedAtAfterSubscribe)
        #expect(try await cache.feedValidators(forPodcastID: Self.oldFeedURL) == refreshedValidators)
    }

    @Test("An http feed with no matching https twin stays put")
    func httpFeedWithMismatchedTwinStaysPut() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let httpFeedURL = "http://example.com/insecure.xml"
        let httpsFeedURL = "https://example.com/insecure.xml"
        let httpSnapshot = makeSnapshot(feedURL: httpFeedURL, title: "Insecure Show")
        let unrelatedSnapshot = makeSnapshot(
            feedURL: httpsFeedURL,
            title: "A Different Show",
            guid: "unrelated-guid",
            audioPath: "unrelated.mp3",
            episodeTitle: "Unrelated"
        )
        let service = OutcomeStubFeedService(outcomes: [
            httpFeedURL: [FeedFetchOutcome(snapshot: httpSnapshot)],
            httpsFeedURL: [FeedFetchOutcome(snapshot: unrelatedSnapshot)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        try await store.subscribe(to: httpFeedURL, modelContext: context)

        await store.refresh(feedURL: httpFeedURL, modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [httpFeedURL])
        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).isEmpty)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        feedURL: String,
        title: String,
        guid: String = "shared-guid",
        audioPath: String = "episode.mp3",
        episodeTitle: String = "Episode One"
    ) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let audioURL = URL(string: "https://audio.example.com/\(audioPath)")!
        return FeedSnapshot(
            podcast: Podcast(
                id: URLCanonicalizer.podcastID(for: url),
                feedURL: url,
                title: title
            ),
            episodes: [
                Episode(
                    id: EpisodeIdentity.makeID(
                        feedURL: url,
                        guid: guid,
                        audioURL: audioURL,
                        title: episodeTitle,
                        publishedAt: Self.dateOne
                    ),
                    podcastID: URLCanonicalizer.podcastID(for: url),
                    podcastTitle: title,
                    title: episodeTitle,
                    publishedAt: Self.dateOne,
                    duration: 120,
                    audioURL: audioURL,
                    guid: guid
                )
            ]
        )
    }
}

private actor OutcomeStubFeedService: FeedService {
    private var outcomesByURL: [String: [FeedFetchOutcome]]

    init(outcomes: [String: [FeedFetchOutcome]]) {
        outcomesByURL = outcomes
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = try await fetchFeedOutcome(at: url, validators: nil).snapshot else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        return snapshot
    }

    func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome {
        let key = url.absoluteString
        guard var outcomes = outcomesByURL[key], let next = outcomes.first else {
            throw OutcomeStubFeedError(message: "No stub outcome for \(key)")
        }
        if outcomes.count > 1 {
            outcomes.removeFirst()
            outcomesByURL[key] = outcomes
        }
        return next
    }
}

private struct OutcomeStubFeedError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
