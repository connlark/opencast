import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("LibraryStore state machine")
struct LibraryStoreStateMachineTests {
    // MARK: - State machine

    @Test("Single-feed fetch failure lands in the refresh log, not store state")
    func singleFeedFetchFailureRecordsRefreshLogNotStoreFailure() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/state-fetch-failure.xml"
        let service = ScriptedFeedService(scripts: [feedURL: [.failure("Feed exploded")]])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "State Fetch Failure"))
        try context.save()
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedURL, modelContext: context)

        #expect(store.state == .idle)
        #expect(store.lastErrorMessage == nil)
        #expect(store.latestRefreshLog(feedURL: feedURL)?.errorMessage == "Feed exploded")
        #expect(store.refreshingFeedURLs.isEmpty)
    }

    @Test("Single-feed store failure sets failed state and lastErrorMessage")
    func singleFeedStoreFailureSetsFailedState() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/state-store-failure.xml"
        let service = ScriptedFeedService(scripts: [
            feedURL: [.success(makeSnapshot(feedURL: feedURL, episodeID: "state-store-failure-episode"))]
        ])
        let store = LibraryStore(
            feedService: service,
            localCache: RefreshLogWriteFailingCacheStore(wrapping: SQLiteLocalLibraryCacheStore.inMemory())
        )

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "State Store Failure"))
        try context.save()
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedURL, modelContext: context)

        #expect(store.state == .failed("Refresh log write failed"))
        #expect(store.lastErrorMessage == "Refresh log write failed")
        #expect(store.refreshingFeedURLs.isEmpty)
    }

    @Test("Cancelled refreshAll returns to idle without surfacing an error")
    func refreshAllCancellationEndsIdleWithoutError() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURLA = "https://example.com/cancel-a.xml"
        let feedURLB = "https://example.com/cancel-b.xml"
        let service = ScriptedFeedService(scripts: [
            feedURLA: [.hangUntilCancelled],
            feedURLB: [.hangUntilCancelled]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURLA, title: "Cancel A"))
        context.insert(SubscriptionRecord(feedURL: feedURLB, title: "Cancel B"))
        try context.save()
        await store.load(modelContext: context)

        let refreshTask = Task {
            await store.refreshAll(modelContext: context)
        }
        #expect(await service.waitForRequestCount(2))
        #expect(store.state == .refreshing)

        refreshTask.cancel()
        await refreshTask.value

        #expect(store.state == .idle)
        #expect(store.lastErrorMessage == nil)
        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(store.refreshCompletedToken == 0)
    }

    @Test("A completing single-feed refresh does not stomp refreshAll's state")
    func singleFeedRefreshDuringRefreshAllDoesNotStompState() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURLA = "https://example.com/stomp-a.xml"
        let feedURLB = "https://example.com/stomp-b.xml"
        let gate = AsyncTestGate()
        let snapshotB = makeSnapshot(feedURL: feedURLB, episodeID: "stomp-b-episode")
        let service = ScriptedFeedService(scripts: [
            feedURLA: [.gatedSuccess(makeSnapshot(feedURL: feedURLA, episodeID: "stomp-a-episode"), gate)],
            feedURLB: [.success(snapshotB), .success(snapshotB)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURLA, title: "Stomp A"))
        context.insert(SubscriptionRecord(feedURL: feedURLB, title: "Stomp B"))
        try context.save()
        await store.load(modelContext: context)

        let refreshAllTask = Task {
            await store.refreshAll(modelContext: context)
        }
        #expect(await service.waitForRequestCount(2))

        await store.refresh(feedURL: feedURLB, modelContext: context)

        #expect(store.state == .refreshing)
        #expect(store.isRefreshing(feedURL: feedURLA))

        await gate.release()
        await refreshAllTask.value

        #expect(store.state == .idle)
        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(store.refreshCompletedToken == 1)
    }

    @Test("Repair and unsubscribe reset a failed store to idle")
    func repairAndUnsubscribeResetFailedStateToIdle() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/reset-subscribed.xml"
        let missingFeedURL = "https://example.com/reset-missing.xml"
        let service = ScriptedFeedService(scripts: [:])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Reset Show"))
        try context.save()
        await store.load(modelContext: context)

        // Subscribe failures surface through state alone; lastErrorMessage
        // stays untouched on this path.
        try? await store.subscribe(to: missingFeedURL, modelContext: context)
        #expect(store.state == .failed("No scripted response for \(missingFeedURL)"))

        _ = try await store.repairSyncDuplicates(modelContext: context)
        #expect(store.state == .idle)
        #expect(store.lastErrorMessage == nil)

        try? await store.subscribe(to: missingFeedURL, modelContext: context)
        #expect(store.state == .failed("No scripted response for \(missingFeedURL)"))

        await store.unsubscribe(feedURL: feedURL, modelContext: context)
        #expect(store.state == .idle)
        #expect(store.lastErrorMessage == nil)
    }

    // MARK: - Busy-marker balance under overlap

    @Test("Overlapping single-feed and bulk refresh markers balance on success")
    func overlappingRefreshMarkersBalanceOnSuccess() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/overlap-success.xml"
        let gate = AsyncTestGate()
        let snapshot = makeSnapshot(feedURL: feedURL, episodeID: "overlap-success-episode")
        let service = ScriptedFeedService(scripts: [
            feedURL: [.gatedSuccess(snapshot, gate), .gatedSuccess(snapshot, gate)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Overlap Success"))
        try context.save()
        await store.load(modelContext: context)

        let refreshAllTask = Task {
            await store.refreshAll(modelContext: context)
        }
        #expect(await service.waitForRequestCount(1))
        let singleRefreshTask = Task {
            await store.refresh(feedURL: feedURL, modelContext: context)
        }
        #expect(await service.waitForRequestCount(2))
        #expect(store.refreshingFeedURLs == [feedURL])

        await gate.release()
        await refreshAllTask.value
        await singleRefreshTask.value

        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(!store.isRefreshing(feedURL: feedURL))
        #expect(store.state == .idle)
        #expect(store.refreshCompletedToken == 1)
    }

    @Test("Overlapping single-feed and bulk refresh markers balance on fetch error")
    func overlappingRefreshMarkersBalanceOnError() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/overlap-error.xml"
        let gate = AsyncTestGate()
        let service = ScriptedFeedService(scripts: [
            feedURL: [.gatedFailure("Overlap fetch failed", gate), .gatedFailure("Overlap fetch failed", gate)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Overlap Error"))
        try context.save()
        await store.load(modelContext: context)

        let refreshAllTask = Task {
            await store.refreshAll(modelContext: context)
        }
        #expect(await service.waitForRequestCount(1))
        let singleRefreshTask = Task {
            await store.refresh(feedURL: feedURL, modelContext: context)
        }
        #expect(await service.waitForRequestCount(2))
        #expect(store.refreshingFeedURLs == [feedURL])

        await gate.release()
        await refreshAllTask.value
        await singleRefreshTask.value

        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(!store.isRefreshing(feedURL: feedURL))
        #expect(store.state == .idle)
        // Per-feed fetch failures land in refresh logs; the bulk flow itself
        // completes, so the completion token still advances.
        #expect(store.refreshCompletedToken == 1)
        #expect(store.latestRefreshLog(feedURL: feedURL)?.errorMessage == "Overlap fetch failed")
    }

    @Test("Overlapping single-feed and bulk refresh markers balance on cancellation")
    func overlappingRefreshMarkersBalanceOnCancellation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/overlap-cancel.xml"
        let service = ScriptedFeedService(scripts: [
            feedURL: [.hangUntilCancelled, .hangUntilCancelled]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Overlap Cancel"))
        try context.save()
        await store.load(modelContext: context)

        let refreshAllTask = Task {
            await store.refreshAll(modelContext: context)
        }
        #expect(await service.waitForRequestCount(1))
        let singleRefreshTask = Task {
            await store.refresh(feedURL: feedURL, modelContext: context)
        }
        #expect(await service.waitForRequestCount(2))
        #expect(store.refreshingFeedURLs == [feedURL])

        refreshAllTask.cancel()
        singleRefreshTask.cancel()
        await refreshAllTask.value
        await singleRefreshTask.value

        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(!store.isRefreshing(feedURL: feedURL))
        #expect(store.state == .idle)
        #expect(store.lastErrorMessage == nil)
        #expect(store.refreshCompletedToken == 0)
    }

    // MARK: - Data nuke reset

    @Test("resetAfterDataNuke empties every facade-readable surface")
    func resetAfterDataNukeEmptiesEveryFacadeSurface() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/nuke.xml"
        let episodeID = "nuke-episode"
        let artworkURL = try #require(URL(string: "https://example.com/artwork/nuke.png"))
        let snapshot = makeSnapshot(feedURL: feedURL, episodeID: episodeID, artworkURL: artworkURL)
        let service = ScriptedFeedService(scripts: [feedURL: [.success(snapshot), .success(snapshot)]])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        await store.load(modelContext: context)
        try await store.subscribe(to: feedURL, modelContext: context)
        await store.refresh(feedURL: feedURL, modelContext: context)
        store.updateProgress(
            episodeID: episodeID,
            podcastID: feedURL,
            position: 42,
            duration: 120,
            modelContext: context
        )
        let episode = try #require(store.episode(with: episodeID))
        let preview = try makePreview(artworkURL: artworkURL)
        #expect(store.updateArtworkPreview(preview, for: episode))
        await store.waitForPendingCacheWrites()

        #expect(!store.subscriptions.isEmpty)
        #expect(!store.episodes.isEmpty)
        #expect(!store.refreshLogs.isEmpty)
        #expect(!store.latestSuccessfulRefreshByFeedURL.isEmpty)
        #expect(store.progressRecord(for: episodeID) != nil)
        #expect(store.artworkPreview(for: episode) == preview)

        store.prepareForDataNuke()
        store.resetAfterDataNuke()

        #expect(store.state == .idle)
        #expect(store.subscriptions.isEmpty)
        #expect(store.episodes.isEmpty)
        #expect(store.inboxEpisodes.isEmpty)
        #expect(store.progressRecords.isEmpty)
        #expect(store.refreshLogs.isEmpty)
        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(store.activePodcastIDs.isEmpty)
        #expect(store.visibleEpisodeIDs.isEmpty)
        #expect(store.podcastCacheByFeedURL.isEmpty)
        #expect(store.latestRefreshLogByFeedURL.isEmpty)
        #expect(store.latestSuccessfulRefreshByFeedURL.isEmpty)
        #expect(store.lastErrorMessage == nil)
        #expect(store.latestRefreshOverall == nil)
        #expect(store.latestRefreshLog(feedURL: feedURL) == nil)
        #expect(store.podcastCache(for: feedURL) == nil)
        #expect(store.episode(with: episodeID) == nil)
        #expect(store.episodes(forPodcastID: feedURL).isEmpty)
        #expect(store.progressRecord(for: episodeID) == nil)
        #expect(store.artworkPreview(for: episode) == nil)
        #expect(store.feedURLStringsNeedingLocalCache.isEmpty)
        #expect(!store.isActivelySubscribed(to: feedURL))
    }

    // MARK: - Batch subscribe

    @Test("subscribeBatch accumulates per-feed failures alongside successes")
    func subscribeBatchAccumulatesPartialFailures() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let goodFeedURLA = "https://example.com/batch-good-a.xml"
        let goodFeedURLB = "https://example.com/batch-good-b.xml"
        let badFeedURL = "https://example.com/batch-bad.xml"
        let schemelessFeedURL = "example.com/batch-no-scheme.xml"
        let service = ScriptedFeedService(scripts: [
            goodFeedURLA: [.success(makeSnapshot(feedURL: goodFeedURLA, episodeID: "batch-good-a-episode"))],
            goodFeedURLB: [.success(makeSnapshot(feedURL: goodFeedURLB, episodeID: "batch-good-b-episode"))],
            badFeedURL: [.failure("Feed rejected")]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        await store.load(modelContext: context)

        let result = try await store.subscribeBatch(
            to: [goodFeedURLA, badFeedURL, schemelessFeedURL, goodFeedURLB],
            modelContext: context
        )

        #expect(result.subscribedFeedURLStrings.sorted() == [goodFeedURLA, goodFeedURLB])
        #expect(result.failures.count == 2)
        let failureMessagesByFeedURL = Dictionary(
            result.failures.map { ($0.feedURLString, $0.message) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(failureMessagesByFeedURL[badFeedURL] == "Feed rejected")
        #expect(failureMessagesByFeedURL[schemelessFeedURL] == OpenCastCoreError.invalidFeedURL.localizedDescription)

        let subscribedFeedURLs = try context.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.feedURL)
        #expect(subscribedFeedURLs.sorted() == [goodFeedURLA, goodFeedURLB])
        #expect(store.syncedStoreSelfSaveCount == 2)
    }

    @Test("subscribeBatch cancellation aborts the whole batch")
    func subscribeBatchCancellationAbortsBatch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURLs = [
            "https://example.com/batch-cancel-a.xml",
            "https://example.com/batch-cancel-b.xml",
            "https://example.com/batch-cancel-c.xml"
        ]
        let service = ScriptedFeedService(
            scripts: Dictionary(uniqueKeysWithValues: feedURLs.map { ($0, [ScriptedFeedService.Script.hangUntilCancelled]) })
        )
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        await store.load(modelContext: context)

        let batchTask = Task {
            try await store.subscribeBatch(to: feedURLs, modelContext: context)
        }
        #expect(await service.waitForRequestCount(3))
        batchTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await batchTask.value
        }
        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).isEmpty)
        #expect(store.syncedStoreSelfSaveCount == 0)
    }

    // MARK: - Credit inventory

    @Test("Each crediting operation advances syncedStoreSelfSaveCount exactly once")
    func creditInventoryAdvancesExactlyOncePerOperation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/credit.xml"
        let migratedFeedURL = "https://example.com/credit-migrated.xml"
        let strayFeedURL = "https://example.com/credit-stray.xml"
        let audioURL = "https://example.com/credit-audio.mp3"
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let originalSnapshot = makeSnapshot(
            feedURL: feedURL,
            episodeID: "credit-episode-1",
            audioURL: audioURL,
            publishedAt: publishedAt
        )
        // Same audio URL and title under a new episode ID: the refresh
        // reconciles credit-episode-1 onto credit-episode-2.
        let reidentifiedSnapshot = makeSnapshot(
            feedURL: feedURL,
            episodeID: "credit-episode-2",
            audioURL: audioURL,
            publishedAt: publishedAt
        )
        let migratedSnapshot = makeSnapshot(
            feedURL: migratedFeedURL,
            episodeID: "credit-episode-3",
            audioURL: audioURL,
            publishedAt: publishedAt
        )
        let service = ScriptedFeedService(scripts: [
            feedURL: [.success(originalSnapshot), .success(reidentifiedSnapshot)],
            migratedFeedURL: [.success(migratedSnapshot)]
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        await store.load(modelContext: context)
        #expect(store.syncedStoreSelfSaveCount == 0)

        // upsert: subscription insert.
        try await store.subscribe(to: feedURL, modelContext: context)
        #expect(store.syncedStoreSelfSaveCount == 1)

        // repairSyncDuplicates: merge a duplicated subscription record.
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Credit Duplicate"))
        try context.save()
        let repairResult = try await store.repairSyncDuplicates(modelContext: context)
        #expect(repairResult.hasChanges)
        #expect(store.syncedStoreSelfSaveCount == 2)

        // setAdAutoDetectEnabled: synced flag flip.
        #expect(store.setAdAutoDetectEnabled(true, feedURL: feedURL, modelContext: context))
        #expect(store.syncedStoreSelfSaveCount == 3)

        // updateProgress: progress row insert.
        #expect(store.updateProgress(
            episodeID: "credit-episode-1",
            podcastID: feedURL,
            position: 42,
            duration: 120,
            modelContext: context
        ))
        #expect(store.syncedStoreSelfSaveCount == 4)

        // markAllPlayed: batched progress save.
        #expect(store.markAllPlayed(forPodcastID: feedURL, modelContext: context))
        #expect(store.syncedStoreSelfSaveCount == 5)

        // clearProgress: progress delete plus tombstone.
        let episode = try #require(store.episode(with: "credit-episode-1"))
        #expect(store.clearProgress(for: episode, modelContext: context))
        #expect(store.syncedStoreSelfSaveCount == 6)

        // clearProgressForUnsubscribedShows: unsubscribed history sweep.
        context.insert(
            EpisodeProgressRecord(
                episodeID: "credit-stray-episode",
                podcastID: strayFeedURL,
                position: 3600,
                duration: 3600,
                isPlayed: true
            )
        )
        try context.save()
        #expect(store.clearProgressForUnsubscribedShows(modelContext: context) == 1)
        #expect(store.syncedStoreSelfSaveCount == 7)

        // reconcileEpisodeIdentities: refresh that re-keys an episode identity.
        await store.refresh(feedURL: feedURL, modelContext: context)
        #expect(store.state == .idle)
        #expect(store.episode(with: "credit-episode-2") != nil)
        #expect(store.syncedStoreSelfSaveCount == 8)

        // migrateSubscription: relocation onto a new canonical feed URL.
        try await store.migrateSubscription(
            from: feedURL,
            toFeedURL: try #require(URL(string: migratedFeedURL)),
            modelContext: context
        )
        #expect(store.syncedStoreSelfSaveCount == 9)

        // unsubscribe: subscription delete plus tombstone.
        await store.unsubscribe(feedURL: migratedFeedURL, modelContext: context)
        #expect(store.state == .idle)
        #expect(store.syncedStoreSelfSaveCount == 10)
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        feedURL: String,
        episodeID: String,
        audioURL: String? = nil,
        publishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        artworkURL: URL? = nil
    ) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: "State Machine Show",
                author: "State Machine Author",
                summary: "State Machine Summary",
                artworkURL: artworkURL
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: episodeID),
                    podcastID: podcastID,
                    podcastTitle: "State Machine Show",
                    title: "State Machine Episode",
                    publishedAt: publishedAt,
                    duration: 120,
                    audioURL: URL(string: audioURL ?? "https://example.com/\(episodeID).mp3"),
                    artworkURL: artworkURL,
                    guid: episodeID
                )
            ]
        )
    }

    private func makePreview(artworkURL: URL) throws -> ArtworkPreview {
        let rgbData = Data((0..<(8 * 8)).flatMap { _ in [UInt8(240), 44, 32] })
        return try #require(ArtworkPreview(
            version: ArtworkPreview.currentVersion,
            canonicalArtworkURLKey: ArtworkPreview.canonicalArtworkURLKey(for: artworkURL.absoluteString) ?? "",
            sourceHash: "state-machine-source",
            pixelWidth: 8,
            pixelHeight: 8,
            rgbData: rgbData
        ))
    }
}

private actor ScriptedFeedService: FeedService {
    enum Script: Sendable {
        case success(FeedSnapshot)
        case failure(String)
        case gatedSuccess(FeedSnapshot, AsyncTestGate)
        case gatedFailure(String, AsyncTestGate)
        case hangUntilCancelled
    }

    private var scriptsByURL: [String: [Script]]
    private var requestedURLs: [String] = []

    init(scripts: [String: [Script]]) {
        scriptsByURL = scripts
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let key = url.absoluteString
        requestedURLs.append(key)

        guard var scripts = scriptsByURL[key],
              !scripts.isEmpty
        else {
            throw ScriptedFeedError(message: "No scripted response for \(key)")
        }

        let script = scripts.removeFirst()
        scriptsByURL[key] = scripts

        switch script {
        case .success(let snapshot):
            return snapshot
        case .failure(let message):
            throw ScriptedFeedError(message: message)
        case .gatedSuccess(let snapshot, let gate):
            await gate.wait()
            return snapshot
        case .gatedFailure(let message, let gate):
            await gate.wait()
            throw ScriptedFeedError(message: message)
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(600))
            throw ScriptedFeedError(message: "Hang response outlived its test")
        }
    }

    func waitForRequestCount(_ count: Int) async -> Bool {
        for _ in 0..<1_000 {
            if requestedURLs.count >= count {
                return true
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        return requestedURLs.count >= count
    }
}

/// Forwards everything to a real in-memory cache store but fails refresh-log
/// inserts, the narrowest way to drive a refresh into the store-failure path.
private struct RefreshLogWriteFailingCacheStore: LocalLibraryCacheStore {
    let wrapped: any LocalLibraryCacheStore

    init(wrapping wrapped: any LocalLibraryCacheStore) {
        self.wrapped = wrapped
    }

    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        try await wrapped.loadLibrary(activePodcastIDs: activePodcastIDs)
    }

    func allRefreshLogs() async throws -> [RefreshLogSnapshot] {
        try await wrapped.allRefreshLogs()
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        try await wrapped.episodeDetail(episodeID: episodeID)
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        try await wrapped.showNotesHTMLByEpisodeID(activePodcastIDs: activePodcastIDs)
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {
        try await wrapped.upsertCache(from: snapshot, refreshedAt: refreshedAt)
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {
        try await wrapped.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
    }

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {
        try await wrapped.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
    }

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {
        throw ScriptedFeedError(message: "Refresh log write failed")
    }

    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators? {
        try await wrapped.feedValidators(forPodcastID: podcastID)
    }

    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws {
        try await wrapped.updateFeedValidators(validators, forPodcastID: podcastID)
    }

    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot] {
        try await wrapped.cachedEpisodes(forPodcastID: podcastID)
    }

    func deleteEpisodes(episodeIDs: [String]) async throws {
        try await wrapped.deleteEpisodes(episodeIDs: episodeIDs)
    }

    func deleteCache(forPodcastID podcastID: String) async throws {
        try await wrapped.deleteCache(forPodcastID: podcastID)
    }

    func deleteAllLocalCache() async throws {
        try await wrapped.deleteAllLocalCache()
    }

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws {
        try await wrapped.replaceNotificationFeedHealth(records)
    }

    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth] {
        try await wrapped.notificationFeedHealthByFeedURL()
    }

    func hasCompletedLegacyImport() async throws -> Bool {
        try await wrapped.hasCompletedLegacyImport()
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {
        try await wrapped.importLegacyCache(
            podcasts: podcasts,
            episodes: episodes,
            refreshLogs: refreshLogs
        )
    }
}

private struct ScriptedFeedError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
