import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Sync tombstones and deterministic duplicate repair")
struct SyncTombstoneRepairTests {
    private static let feedURL = "https://example.com/tombstone.xml"
    private static let otherFeedURL = "https://example.com/other.xml"
    private static let clearInstant = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Subscription tombstones delete stale copies and keep resubscribes")
    func subscriptionTombstonesDeleteStaleCopiesAndKeepResubscribes() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SyncTombstoneRecord(scope: .subscription, feedURL: Self.feedURL, deletedAt: Self.clearInstant)
        )
        context.insert(
            SubscriptionRecord(
                feedURL: Self.feedURL,
                title: "Stale Copy",
                subscribedAt: Self.clearInstant.addingTimeInterval(-100)
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: Self.feedURL,
                title: "Resubscribed",
                subscribedAt: Self.clearInstant.addingTimeInterval(100)
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: Self.otherFeedURL,
                title: "Unrelated",
                subscribedAt: Self.clearInstant.addingTimeInterval(-100)
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)

        let titles = try context.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.title).sorted()
        #expect(titles == ["Resubscribed", "Unrelated"])
        #expect(result.tombstonedSubscriptionRecordsDeleted == 1)
        #expect(result.hasIssues)
        #expect(store.syncedStoreSelfSaveCount == 1)
    }

    @Test("Feed progress tombstones clear old history and keep newer listening")
    func feedProgressTombstonesClearOldHistoryAndKeepNewerListening() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SyncTombstoneRecord(scope: .feedProgress, feedURL: Self.feedURL, deletedAt: Self.clearInstant)
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "cleared",
                podcastID: Self.feedURL,
                position: 100,
                isPlayed: true,
                updatedAt: Self.clearInstant.addingTimeInterval(-10)
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "fresh-listen",
                podcastID: Self.feedURL,
                position: 50,
                updatedAt: Self.clearInstant.addingTimeInterval(10)
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "other-feed",
                podcastID: Self.otherFeedURL,
                position: 25,
                updatedAt: Self.clearInstant.addingTimeInterval(-10)
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)

        let survivors = try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).map(\.episodeID).sorted()
        #expect(survivors == ["fresh-listen", "other-feed"])
        #expect(result.tombstonedProgressRecordsDeleted == 1)
    }

    @Test("Episode tombstones clear only the targeted episode")
    func episodeTombstonesClearOnlyTheTargetedEpisode() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SyncTombstoneRecord(
                scope: .episodeProgress,
                feedURL: Self.feedURL,
                episodeID: "cleared-episode",
                deletedAt: Self.clearInstant
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "cleared-episode",
                podcastID: Self.feedURL,
                position: 100,
                updatedAt: Self.clearInstant.addingTimeInterval(-10)
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "kept-episode",
                podcastID: Self.feedURL,
                position: 200,
                updatedAt: Self.clearInstant.addingTimeInterval(-10)
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)

        let survivors = try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).map(\.episodeID)
        #expect(survivors == ["kept-episode"])
        #expect(result.tombstonedProgressRecordsDeleted == 1)
    }

    @Test("Variant-key progress re-keys to the claiming feed and dies under its tombstone")
    func variantKeyProgressReKeysToTheClaimingFeedAndDiesUnderItsTombstone() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        context.insert(
            SyncTombstoneRecord(scope: .feedProgress, feedURL: Self.feedURL, deletedAt: Self.clearInstant)
        )
        // Written long ago under a raw variant of the claiming feed's URL —
        // the exact shadow-record shape that used to dodge every clear.
        context.insert(
            EpisodeProgressRecord(
                episodeID: "shared-episode",
                podcastID: "http://example.com",
                position: 5,
                isPlayed: true,
                updatedAt: Self.clearInstant.addingTimeInterval(-1_000),
                dedupeUUID: ""
            )
        )
        try context.save()

        let result = try SyncDuplicateRepairer.repair(
            modelContext: context,
            claimedFeedURLsByEpisodeID: ["shared-episode": Self.feedURL]
        )

        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(result.normalizedProgressRecords == 1)
        #expect(result.tombstonedProgressRecordsDeleted == 1)
    }

    @Test("Variant-key duplicates merge once normalized")
    func variantKeyDuplicatesMergeOnceNormalized() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        context.insert(
            EpisodeProgressRecord(
                episodeID: "shared-episode",
                podcastID: "http://example.com",
                position: 42,
                updatedAt: Self.clearInstant,
                dedupeUUID: "aaaaaaaa-2222-0000-0000-000000000000"
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "shared-episode",
                podcastID: Self.feedURL,
                position: 900,
                isPlayed: true,
                updatedAt: Self.clearInstant.addingTimeInterval(10),
                dedupeUUID: "bbbbbbbb-2222-0000-0000-000000000000"
            )
        )
        try context.save()

        let result = try SyncDuplicateRepairer.repair(
            modelContext: context,
            claimedFeedURLsByEpisodeID: ["shared-episode": Self.feedURL]
        )

        let records = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(records.count == 1)
        #expect(records.first?.podcastID == Self.feedURL)
        #expect(records.first?.isPlayed == true)
        #expect(result.normalizedProgressRecords == 1)
        #expect(result.progressGroupsMerged == 1)
    }

    @Test("Episode tombstones match variant keys by episode ID")
    func episodeTombstonesMatchVariantKeysByEpisodeID() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        context.insert(
            SyncTombstoneRecord(
                scope: .episodeProgress,
                feedURL: Self.feedURL,
                episodeID: "shared-episode",
                deletedAt: Self.clearInstant
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "shared-episode",
                podcastID: "http://example.com",
                position: 30,
                updatedAt: Self.clearInstant.addingTimeInterval(-10)
            )
        )
        try context.save()

        let result = try SyncDuplicateRepairer.repair(modelContext: context)

        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(result.tombstonedProgressRecordsDeleted == 1)
    }

    @Test("Superseded and expired tombstones are garbage collected")
    func supersededAndExpiredTombstonesAreGarbageCollected() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let now = Self.clearInstant

        context.insert(
            SyncTombstoneRecord(
                scope: .subscription,
                feedURL: Self.feedURL,
                deletedAt: now.addingTimeInterval(-100)
            )
        )
        context.insert(
            SyncTombstoneRecord(
                scope: .subscription,
                feedURL: Self.feedURL,
                deletedAt: now.addingTimeInterval(-50)
            )
        )
        context.insert(
            SyncTombstoneRecord(
                scope: .feedProgress,
                feedURL: Self.otherFeedURL,
                deletedAt: now.addingTimeInterval(-SyncDuplicateRepairer.tombstoneRetentionPeriod - 60)
            )
        )
        try context.save()

        let result = try SyncDuplicateRepairer.repair(modelContext: context, now: now)

        let remaining = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.deletedAt == now.addingTimeInterval(-50))
        #expect(result.expiredTombstonesDeleted == 2)
        #expect(result.hasChanges)
        #expect(!result.hasIssues)
    }

    @Test("Unsubscribe writes a subscription tombstone only by default")
    func unsubscribeWritesASubscriptionTombstoneOnlyByDefault() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Show"))
        try context.save()
        await store.load(modelContext: context)

        await store.unsubscribe(feedURL: Self.feedURL, modelContext: context)

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(tombstones.map(\.scope) == [SyncTombstoneScope.subscription.rawValue])
        #expect(tombstones.first?.feedURL == Self.feedURL)
        #expect(store.syncedStoreSelfSaveCount == 1)
    }

    @Test("Unsubscribe with clear history writes subscription and feed tombstones")
    func unsubscribeWithClearHistoryWritesSubscriptionAndFeedTombstones() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Show"))
        try context.save()
        await store.load(modelContext: context)

        await store.unsubscribe(feedURL: Self.feedURL, modelContext: context, clearListeningHistory: true)

        let scopes = try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).map(\.scope).sorted()
        #expect(
            scopes == [
                SyncTombstoneScope.feedProgress.rawValue,
                SyncTombstoneScope.subscription.rawValue
            ]
        )
    }

    @Test("Manual unfollowed clear writes per-feed tombstones and prune writes none")
    func manualUnfollowedClearWritesPerFeedTombstonesAndPruneWritesNone() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let staleUpdatedAt = Date.now.addingTimeInterval(-LibraryStore.trivialProgressPrunableMinAge - 60)

        context.insert(
            EpisodeProgressRecord(episodeID: "cleared-a", podcastID: Self.feedURL, position: 900, isPlayed: true)
        )
        context.insert(
            EpisodeProgressRecord(episodeID: "cleared-b", podcastID: Self.otherFeedURL, position: 700)
        )
        try context.save()

        #expect(store.clearProgressForUnsubscribedShows(modelContext: context) == 2)
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(tombstones.map(\.scope) == Array(repeating: SyncTombstoneScope.feedProgress.rawValue, count: 2))
        #expect(tombstones.map(\.feedURL).sorted() == [Self.otherFeedURL, Self.feedURL].sorted())

        context.insert(
            EpisodeProgressRecord(
                episodeID: "trivial",
                podcastID: "https://example.com/trivial.xml",
                position: 10,
                updatedAt: staleUpdatedAt
            )
        )
        try context.save()

        #expect(store.pruneTrivialUnsubscribedProgressRecords(modelContext: context) == 1)
        let tombstonesAfterPrune = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(tombstonesAfterPrune.count == 2)
    }

    @Test("Clearing one episode's progress writes an episode tombstone")
    func clearingOneEpisodesProgressWritesAnEpisodeTombstone() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episode = EpisodeListItemSnapshot(
            episodeID: "cleared-episode",
            podcastID: Self.feedURL,
            podcastTitle: "Show",
            title: "Cleared Episode",
            summary: nil,
            publishedAt: Self.clearInstant,
            duration: 120,
            audioURL: "https://example.com/audio.mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
        context.insert(
            EpisodeProgressRecord(episodeID: episode.episodeID, podcastID: episode.podcastID, position: 42)
        )
        try context.save()
        await store.load(modelContext: context)

        #expect(store.clearProgress(for: episode, modelContext: context))

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(tombstones.map(\.scope) == [SyncTombstoneScope.episodeProgress.rawValue])
        #expect(tombstones.first?.episodeID == episode.episodeID)
        #expect(tombstones.first?.feedURL == Self.feedURL)
    }

    @Test("Duplicate repair keeps the smallest dedupe identity regardless of content")
    func duplicateRepairKeepsTheSmallestDedupeIdentityRegardlessOfContent() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SubscriptionRecord(
                feedURL: Self.feedURL,
                title: "Older Winner Identity",
                subscribedAt: Self.clearInstant.addingTimeInterval(-100),
                lastRefreshAt: Self.clearInstant.addingTimeInterval(-100),
                dedupeUUID: "aaaaaaaa-0000-0000-0000-000000000000"
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: Self.feedURL,
                title: "Fresher Loser Identity",
                author: "Fresher Author",
                subscribedAt: Self.clearInstant,
                lastRefreshAt: Self.clearInstant,
                dedupeUUID: "bbbbbbbb-0000-0000-0000-000000000000"
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "episode",
                podcastID: Self.feedURL,
                position: 30,
                updatedAt: Self.clearInstant.addingTimeInterval(-100),
                dedupeUUID: "aaaaaaaa-1111-0000-0000-000000000000"
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "episode",
                podcastID: Self.feedURL,
                position: 900,
                duration: 1_000,
                isPlayed: true,
                updatedAt: Self.clearInstant,
                dedupeUUID: "bbbbbbbb-1111-0000-0000-000000000000"
            )
        )
        try context.save()

        _ = try await store.repairSyncDuplicates(modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.count == 1)
        #expect(subscriptions.first?.dedupeUUID == "aaaaaaaa-0000-0000-0000-000000000000")
        #expect(subscriptions.first?.title == "Fresher Loser Identity")
        #expect(subscriptions.first?.author == "Fresher Author")
        #expect(subscriptions.first?.lastRefreshAt == Self.clearInstant)
        // Newest wins: an inherited old subscribedAt would drag a resubscribe
        // behind an in-flight subscription tombstone.
        #expect(subscriptions.first?.subscribedAt == Self.clearInstant)

        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.count == 1)
        #expect(progress.first?.dedupeUUID == "aaaaaaaa-1111-0000-0000-000000000000")
        #expect(progress.first?.position == 900)
        #expect(progress.first?.isPlayed == true)
        #expect(progress.first?.updatedAt == Self.clearInstant)
    }

    @Test("Legacy duplicates without identities are replaced by one identified record")
    func legacyDuplicatesWithoutIdentitiesAreReplacedByOneIdentifiedRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SubscriptionRecord(feedURL: Self.feedURL, title: "Legacy Copy A", dedupeUUID: "")
        )
        context.insert(
            SubscriptionRecord(feedURL: Self.feedURL, title: "Legacy Copy B", dedupeUUID: "")
        )
        context.insert(
            EpisodeProgressRecord(episodeID: "legacy", podcastID: Self.feedURL, position: 15, dedupeUUID: "")
        )
        context.insert(
            EpisodeProgressRecord(episodeID: "legacy", podcastID: Self.feedURL, position: 15, dedupeUUID: "")
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.count == 1)
        #expect(subscriptions.first?.dedupeUUID.isEmpty == false)
        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.count == 1)
        #expect(progress.first?.dedupeUUID.isEmpty == false)
        #expect(progress.first?.position == 15)
        #expect(result.subscriptionGroupsMerged == 1)
        #expect(result.progressGroupsMerged == 1)
    }

    @Test("Repair credits the arbiter only when it changes the store")
    func repairCreditsTheArbiterOnlyWhenItChangesTheStore() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Solo Show"))
        try context.save()

        let cleanResult = try await store.repairSyncDuplicates(modelContext: context)
        #expect(!cleanResult.hasChanges)
        #expect(store.syncedStoreSelfSaveCount == 0)

        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Duplicate Show"))
        try context.save()

        let repairResult = try await store.repairSyncDuplicates(modelContext: context)
        #expect(repairResult.hasIssues)
        #expect(store.syncedStoreSelfSaveCount == 1)
    }

    @Test("Refresh with unchanged metadata leaves the synced store untouched")
    func refreshWithUnchangedMetadataLeavesTheSyncedStoreUntouched() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let podcastID = PodcastID(rawValue: Self.feedURL)
        let snapshot = FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: Self.feedURL)!,
                title: "Stable Show",
                author: "Stable Author",
                summary: "Summary",
                websiteURL: nil,
                artworkURL: URL(string: "https://example.com/art.jpg")
            ),
            episodes: []
        )
        let service = RepeatingStubFeedService(snapshotsByURL: [Self.feedURL: snapshot])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        try await store.subscribe(to: Self.feedURL, modelContext: context)
        #expect(store.syncedStoreSelfSaveCount == 1)
        let subscribedRefreshAt = try #require(
            try context.fetch(FetchDescriptor<SubscriptionRecord>()).first?.lastRefreshAt
        )

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        let subscription = try #require(try context.fetch(FetchDescriptor<SubscriptionRecord>()).first)
        #expect(store.syncedStoreSelfSaveCount == 1)
        #expect(subscription.lastRefreshAt == subscribedRefreshAt)
        #expect(subscription.title == "Stable Show")
    }
}

private actor RepeatingStubFeedService: FeedService {
    private let snapshotsByURL: [String: FeedSnapshot]

    init(snapshotsByURL: [String: FeedSnapshot]) {
        self.snapshotsByURL = snapshotsByURL
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = snapshotsByURL[url.absoluteString] else {
            throw OpenCastCoreError.invalidFeedURL
        }
        return snapshot
    }
}
