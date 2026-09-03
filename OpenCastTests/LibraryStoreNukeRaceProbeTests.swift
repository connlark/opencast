import CoreData
import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

/// Interleaving probes behind the LibraryStore split design note (sync-credit
/// and write-generation arbitration, 2026-09-01). Each test forces one
/// specific ordering between a library flow and the data nuke instead of
/// racing wall-clock, and pins what the note claims about that ordering.
/// Observed values are also written to /private/tmp/opencast-nuke-race-probes
/// for the design pass.
@MainActor
@Suite("LibraryStore nuke race probes", .serialized)
struct LibraryStoreNukeRaceProbeTests {
    private static let feedURL = "https://example.com/nuke-race-probe.xml"
    private static let migratedFeedURL = "https://example.com/nuke-race-probe-migrated.xml"
    private static let audioURL = "https://example.com/nuke-race-probe-audio.mp3"
    private static let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("No progress flush lands between the row wipe and the playback unload")
    func progressFlushCannotLandBetweenWipeAndUnload() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false
        )
        let episode = Episode(
            id: EpisodeID(rawValue: "nuke-race-probe-episode"),
            podcastID: PodcastID(rawValue: Self.feedURL),
            podcastTitle: "Probe Show",
            title: "Probe Episode",
            duration: 600,
            audioURL: URL(string: Self.audioURL)
        )
        appModel.startPlaybackProgressPersistence(modelContext: context)
        try appModel.playback.load(episode, startPosition: 42)
        #expect(appModel.flushPlaybackProgress(modelContext: context))
        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        let creditsBeforeNuke = appModel.library.syncedStoreSelfSaveCount

        // Flushes at every main-actor suspension point of the nuke. The
        // position never changes before the wipe, so any save the loop
        // reports is a post-wipe insert.
        let flusher = Task { @MainActor () -> Int in
            var saves = 0
            while !Task.isCancelled {
                if appModel.flushPlaybackProgress(modelContext: context) {
                    saves += 1
                }
                await Task.yield()
            }
            return saves
        }

        try await appModel.nukeAllData(modelContext: context)
        flusher.cancel()
        let savesDuringNuke = await flusher.value
        let rowsAfterNuke = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())

        Self.writeReport("progress-flush-across-nuke", [
            "savesDuringNuke=\(savesDuringNuke)",
            "progressRowsAfterNuke=\(rowsAfterNuke.count)",
            "creditsBefore=\(creditsBeforeNuke) creditsAfter=\(appModel.library.syncedStoreSelfSaveCount)",
            "currentEpisodeAfterNuke=\(String(describing: appModel.playback.currentEpisode?.id.rawValue))"
        ])
        #expect(savesDuringNuke == 0)
        #expect(rowsAfterNuke.isEmpty)
        #expect(appModel.playback.currentEpisode == nil)
        // Exactly the row wipe's own credit: no flush landed a credit of its own.
        #expect(appModel.library.syncedStoreSelfSaveCount == creditsBeforeNuke + 1)
    }

    @Test("A subscribe parked in its fetch across the nuke unwinds as cancellation and writes nothing")
    func subscribeParkedInFetchAcrossNukeWritesNothing() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let snapshot = Self.makeSnapshot(episodeID: "probe-episode-1")
        let feedService = ProbeFeedService(steps: [.hang])
        let appModel = OpenCastAppModel(
            library: LibraryStore(feedService: feedService, localCache: cache),
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)

        let subscribeTask = Task { @MainActor in
            try await appModel.library.subscribe(to: Self.feedURL, modelContext: context)
        }
        #expect(await feedService.waitForHang())

        try await appModel.nukeAllData(modelContext: context)
        let creditsAfterNuke = appModel.library.syncedStoreSelfSaveCount

        await feedService.release(snapshot)
        let subscribeResult = await subscribeTask.result
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let cacheSnapshot = try await cache.loadLibrary(activePodcastIDs: [Self.feedURL])

        Self.writeReport("subscribe-in-fetch-across-nuke", [
            "subscribeThrew=\(Self.describe(subscribeResult))",
            "subscriptionRowsAfterRelease=\(subscriptions.count)",
            "cachedPodcastsAfterRelease=\(cacheSnapshot.podcastsByFeedURL.count)",
            "creditsAfterNuke=\(creditsAfterNuke) creditsAfterRelease=\(appModel.library.syncedStoreSelfSaveCount)",
            "state=\(appModel.library.state)"
        ])
        #expect(throws: CancellationError.self) {
            try subscribeResult.get()
        }
        #expect(subscriptions.isEmpty)
        #expect(cacheSnapshot.podcastsByFeedURL.isEmpty)
        #expect(appModel.library.syncedStoreSelfSaveCount == creditsAfterNuke)
        #expect(appModel.library.subscriptions.isEmpty)
        #expect(appModel.library.state == .idle)
    }

    @Test("A batch subscribe parked in its fetch across the nuke unwinds as cancellation and writes nothing")
    func subscribeBatchParkedInFetchAcrossNukeWritesNothing() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let snapshot = Self.makeSnapshot(episodeID: "probe-episode-1")
        let feedService = ProbeFeedService(steps: [.hang])
        let appModel = OpenCastAppModel(
            library: LibraryStore(feedService: feedService, localCache: cache),
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)

        let batchTask = Task { @MainActor in
            try await appModel.library.subscribeBatch(to: [Self.feedURL], modelContext: context)
        }
        #expect(await feedService.waitForHang())

        try await appModel.nukeAllData(modelContext: context)
        let creditsAfterNuke = appModel.library.syncedStoreSelfSaveCount

        await feedService.release(snapshot)
        let batchResult = await batchTask.result
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let cacheSnapshot = try await cache.loadLibrary(activePodcastIDs: [Self.feedURL])

        Self.writeReport("subscribe-batch-in-fetch-across-nuke", [
            "batchThrew=\(Self.describe(batchResult))",
            "subscriptionRowsAfterRelease=\(subscriptions.count)",
            "cachedPodcastsAfterRelease=\(cacheSnapshot.podcastsByFeedURL.count)",
            "creditsAfterNuke=\(creditsAfterNuke) creditsAfterRelease=\(appModel.library.syncedStoreSelfSaveCount)"
        ])
        #expect(throws: CancellationError.self) {
            _ = try batchResult.get()
        }
        #expect(subscriptions.isEmpty)
        #expect(cacheSnapshot.podcastsByFeedURL.isEmpty)
        #expect(appModel.library.syncedStoreSelfSaveCount == creditsAfterNuke)
        #expect(appModel.library.subscriptions.isEmpty)
    }

    @Test("A subscribe suspended inside upsert does not re-create its subscription after the nuke")
    func subscribeSuspendedInsideUpsertDoesNotResurrectAfterNuke() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gates = LocalCacheGates()
        let cache = GatedLocalLibraryCacheStore(base: SQLiteLocalLibraryCacheStore.inMemory(), gates: gates)
        let feedService = ProbeFeedService(steps: [.snapshot(Self.makeSnapshot(episodeID: "probe-episode-1"))])
        let appModel = OpenCastAppModel(
            library: LibraryStore(feedService: feedService, localCache: cache),
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)

        await gates.armUpsert()
        let subscribeTask = Task { @MainActor in
            try await appModel.library.subscribe(to: Self.feedURL, modelContext: context)
        }
        await gates.reachedUpsert.wait()

        try await appModel.nukeAllData(modelContext: context)
        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).isEmpty)
        let creditsAfterNuke = appModel.library.syncedStoreSelfSaveCount

        await gates.upsertRelease.release()
        let subscribeResult = await subscribeTask.result
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let cacheSnapshot = try await cache.loadLibrary(activePodcastIDs: [Self.feedURL])

        Self.writeReport("subscribe-inside-upsert-across-nuke", [
            "subscribeThrew=\(Self.describe(subscribeResult))",
            "subscriptionRowsAfterRelease=\(subscriptions.count)",
            "cachedPodcastsAfterRelease=\(cacheSnapshot.podcastsByFeedURL.count) cachedEpisodes=\(cacheSnapshot.episodes.count)",
            "creditsAfterNuke=\(creditsAfterNuke) creditsAfterRelease=\(appModel.library.syncedStoreSelfSaveCount)",
            "publishedSubscriptions=\(appModel.library.subscriptions.count)"
        ])
        #expect(throws: CancellationError.self) {
            try subscribeResult.get()
        }
        #expect(subscriptions.isEmpty)
        #expect(cacheSnapshot.podcastsByFeedURL.isEmpty)
        #expect(appModel.library.syncedStoreSelfSaveCount == creditsAfterNuke)
        #expect(appModel.library.subscriptions.isEmpty)
        #expect(appModel.library.state == .idle)
    }

    @Test("A direct feed migration suspended inside its cache write does not re-create the subscription after the nuke")
    func migrationSuspendedInsideCacheWriteDoesNotResurrectAfterNuke() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gates = LocalCacheGates()
        let cache = GatedLocalLibraryCacheStore(base: SQLiteLocalLibraryCacheStore.inMemory(), gates: gates)
        let feedService = ProbeFeedService(steps: [
            .snapshot(Self.makeSnapshot(episodeID: "probe-episode-1")),
            .snapshot(Self.makeSnapshot(feedURL: Self.migratedFeedURL, episodeID: "probe-episode-1-migrated"))
        ])
        let appModel = OpenCastAppModel(
            library: LibraryStore(feedService: feedService, localCache: cache),
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        try await appModel.library.subscribe(to: Self.feedURL, modelContext: context)

        await gates.armUpsert()
        let migrateTask = Task { @MainActor in
            try await appModel.library.migrateSubscription(
                from: Self.feedURL,
                toFeedURL: try #require(URL(string: Self.migratedFeedURL)),
                modelContext: context
            )
        }
        await gates.reachedUpsert.wait()

        try await appModel.nukeAllData(modelContext: context)
        let creditsAfterNuke = appModel.library.syncedStoreSelfSaveCount

        await gates.upsertRelease.release()
        let migrateResult = await migrateTask.result
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())

        Self.writeReport("migration-inside-cache-write-across-nuke", [
            "migrateThrew=\(Self.describe(migrateResult))",
            "subscriptionRowsAfterRelease=\(subscriptions.map(\.feedURL))",
            "tombstonesAfterRelease=\(tombstones.count)",
            "creditsAfterNuke=\(creditsAfterNuke) creditsAfterRelease=\(appModel.library.syncedStoreSelfSaveCount)"
        ])
        #expect(throws: CancellationError.self) {
            try migrateResult.get()
        }
        #expect(subscriptions.isEmpty)
        #expect(tombstones.isEmpty)
        #expect(appModel.library.syncedStoreSelfSaveCount == creditsAfterNuke)
    }

    @Test("A refresh suspended inside upsert saves no synced rows after the write generation is invalidated")
    func refreshSuspendedInsideUpsertSavesNothingAfterInvalidation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gates = LocalCacheGates()
        let cache = GatedLocalLibraryCacheStore(base: SQLiteLocalLibraryCacheStore.inMemory(), gates: gates)
        // Same audio URL, title, and date under a new episode ID, plus a
        // renamed show: the refresh reconciles the identity (one synced
        // save) and then updates the subscription metadata (a second).
        let feedService = ProbeFeedService(steps: [
            .snapshot(Self.makeSnapshot(episodeID: "probe-episode-1")),
            .snapshot(Self.makeSnapshot(episodeID: "probe-episode-2", podcastTitle: "Probe Show Renamed"))
        ])
        let store = LibraryStore(feedService: feedService, localCache: cache)
        await store.load(modelContext: context)
        try await store.subscribe(to: Self.feedURL, modelContext: context)
        #expect(store.syncedStoreSelfSaveCount == 1)

        await gates.armUpsert()
        let refreshTask = Task { @MainActor in
            await store.refresh(feedURL: Self.feedURL, modelContext: context)
        }
        await gates.reachedUpsert.wait()
        store.prepareForDataNuke()
        let creditsAtInvalidation = store.syncedStoreSelfSaveCount

        await gates.upsertRelease.release()
        await refreshTask.value
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        let subscriptionTitle = try context.fetch(FetchDescriptor<SubscriptionRecord>()).first?.title

        Self.writeReport("refresh-inside-upsert-after-invalidation", [
            "creditsAtInvalidation=\(creditsAtInvalidation) creditsAfterRefresh=\(store.syncedStoreSelfSaveCount)",
            "tombstonesWrittenAfterInvalidation=\(tombstones.count)",
            "subscriptionTitleAfterRefresh=\(String(describing: subscriptionTitle))",
            "state=\(store.state)"
        ])
        #expect(store.syncedStoreSelfSaveCount == creditsAtInvalidation)
        #expect(tombstones.isEmpty)
        #expect(subscriptionTitle == "Probe Show")
        #expect(store.state == .idle)
    }

    @Test("A refresh unwinding after the runtime reset does not republish the cache")
    func refreshUnwindingAfterResetDoesNotRepublishCache() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gates = LocalCacheGates()
        let cache = GatedLocalLibraryCacheStore(base: SQLiteLocalLibraryCacheStore.inMemory(), gates: gates)
        let snapshot = Self.makeSnapshot(episodeID: "probe-episode-1")
        let feedService = ProbeFeedService(steps: [.snapshot(snapshot), .snapshot(snapshot), .hang])
        let appModel = OpenCastAppModel(
            library: LibraryStore(feedService: feedService, localCache: cache),
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false
        )
        await appModel.library.load(modelContext: context)
        try await appModel.library.subscribe(to: Self.feedURL, modelContext: context)
        await appModel.library.refresh(feedURL: Self.feedURL, modelContext: context)
        #expect(!appModel.library.refreshLogs.isEmpty)
        #expect(!appModel.library.podcastCacheByFeedURL.isEmpty)

        let refreshTask = Task { @MainActor in
            await appModel.library.refresh(feedURL: Self.feedURL, modelContext: context)
        }
        #expect(await feedService.waitForHang())

        await gates.armDeleteAll()
        let nukeTask = Task { @MainActor in
            try await appModel.nukeAllData(modelContext: context)
        }
        await gates.reachedDeleteAll.wait()
        // The runtime reset has run and the SQLite cache is still populated.
        let refreshLogsAfterReset = appModel.library.refreshLogs.count
        let podcastsAfterReset = appModel.library.podcastCacheByFeedURL.count

        await feedService.release(snapshot)
        await refreshTask.value
        let refreshLogsAfterUnwind = appModel.library.refreshLogs.count
        let podcastsAfterUnwind = appModel.library.podcastCacheByFeedURL.count

        await gates.deleteAllRelease.release()
        try await nukeTask.value

        Self.writeReport("refresh-unwinding-before-cache-delete", [
            "afterReset logs=\(refreshLogsAfterReset) podcasts=\(podcastsAfterReset)",
            "afterUnwind logs=\(refreshLogsAfterUnwind) podcasts=\(podcastsAfterUnwind)",
            "afterNuke logs=\(appModel.library.refreshLogs.count) podcasts=\(appModel.library.podcastCacheByFeedURL.count) episodes=\(appModel.library.episodes.count)",
            "state=\(appModel.library.state)"
        ])
        #expect(refreshLogsAfterReset == 0)
        #expect(podcastsAfterReset == 0)
        #expect(appModel.library.episodes.isEmpty)
        #expect(refreshLogsAfterUnwind == 0)
        #expect(podcastsAfterUnwind == 0)
        #expect(appModel.library.refreshLogs.isEmpty)
        #expect(appModel.library.podcastCacheByFeedURL.isEmpty)
        #expect(appModel.library.state == .idle)
    }

    @Test("A save touching both stores posts one remote-change notification per store")
    func twoStoreSavePostsOneNotificationPerStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastNukeRaceProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let container = try ModelContainer(
            for: OpenCastModelContainerFactory.fullSchema,
            configurations: [
                ModelConfiguration(
                    OpenCastModelContainerFactory.syncedConfigurationName,
                    schema: OpenCastModelContainerFactory.syncedSchema,
                    url: directory.appending(path: "synced.sqlite"),
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    OpenCastModelContainerFactory.localConfigurationName,
                    schema: OpenCastModelContainerFactory.localSchema,
                    url: directory.appending(path: "local.sqlite"),
                    cloudKitDatabase: .none
                )
            ]
        )
        let context = ModelContext(container)

        let log = RemoteChangeLog()
        let containerDirectoryPath = directory.standardizedFileURL.path
        let collector = Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(
                named: Notification.Name.NSPersistentStoreRemoteChange
            ) {
                // Every container in the test process posts on this name, so
                // only this container's two stores are attributed here.
                guard let url = (notification.userInfo?[NSPersistentStoreURLKey] as? URL)?.standardizedFileURL,
                      url.path.hasPrefix(containerDirectoryPath)
                else {
                    continue
                }
                log.storeNames.append(url.lastPathComponent)
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Probe Show"))
        context.insert(LocalPreferenceRecord(key: "nuke-race-probe", value: "1"))
        try context.save()
        try await Task.sleep(for: .milliseconds(500))
        let namesAfterMixedSave = log.storeNames

        context.insert(EpisodeProgressRecord(episodeID: "probe", podcastID: Self.feedURL, position: 10))
        try context.save()
        try await Task.sleep(for: .milliseconds(500))
        collector.cancel()
        let names = log.storeNames

        Self.writeReport("remote-change-notifications", [
            "afterMixedSave=\(namesAfterMixedSave)",
            "afterBothSaves=\(names)"
        ])
        #expect(namesAfterMixedSave.count == 2)
        #expect(names.count == 3)
        #expect(names.filter { $0 == "synced.sqlite" }.count == 2)
        #expect(names.filter { $0 == "local.sqlite" }.count == 1)
    }

    // MARK: - Helpers

    private static func describe<Value>(_ result: Result<Value, any Error>) -> String {
        switch result {
        case .success:
            "no"
        case .failure(let error):
            "yes: \(error)"
        }
    }

    private static func makeSnapshot(
        feedURL: String = feedURL,
        episodeID: String,
        podcastTitle: String = "Probe Show"
    ) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: podcastTitle,
                author: "Probe Author"
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: episodeID),
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: "Probe Episode",
                    publishedAt: publishedAt,
                    duration: 120,
                    audioURL: URL(string: audioURL),
                    guid: episodeID
                )
            ]
        )
    }

    private static func writeReport(_ name: String, _ lines: [String]) {
        let directory = URL(filePath: "/private/tmp/opencast-nuke-race-probes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(
            to: directory.appending(path: "\(name).txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@MainActor
private final class RemoteChangeLog {
    var storeNames: [String] = []
}

private actor AvailableAccountStatusProvider: CloudKitAccountStatusProviding {
    func accountStatus() async throws -> SyncAccountStatus {
        .available
    }
}

private struct ProbeFeedError: Error {
    let message: String
}

private actor ProbeFeedService: FeedService {
    enum Step: Sendable {
        case snapshot(FeedSnapshot)
        case hang
    }

    private var steps: [Step]
    private var isHanging = false
    private var continuation: CheckedContinuation<FeedSnapshot, Never>?

    init(steps: [Step]) {
        self.steps = steps
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard !steps.isEmpty else {
            throw ProbeFeedError(message: "No scripted response for \(url)")
        }
        switch steps.removeFirst() {
        case .snapshot(let snapshot):
            return snapshot
        case .hang:
            isHanging = true
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func release(_ snapshot: FeedSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }

    func waitForHang() async -> Bool {
        for _ in 0..<600 {
            if isHanging {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isHanging
    }
}

/// Arms one-shot holds on specific cache-store calls so a test can park a
/// library flow at an exact await and advance the nuke around it.
actor LocalCacheGates {
    let reachedUpsert = AsyncTestGate()
    let upsertRelease = AsyncTestGate()
    let reachedDeleteAll = AsyncTestGate()
    let deleteAllRelease = AsyncTestGate()
    private(set) var isUpsertArmed = false
    private(set) var isDeleteAllArmed = false

    func armUpsert() {
        isUpsertArmed = true
    }

    func armDeleteAll() {
        isDeleteAllArmed = true
    }
}

private struct GatedLocalLibraryCacheStore: LocalLibraryCacheStore {
    let base: any LocalLibraryCacheStore
    let gates: LocalCacheGates

    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        try await base.loadLibrary(activePodcastIDs: activePodcastIDs)
    }

    func allRefreshLogs() async throws -> [RefreshLogSnapshot] {
        try await base.allRefreshLogs()
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        try await base.episodeDetail(episodeID: episodeID)
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        try await base.showNotesHTMLByEpisodeID(activePodcastIDs: activePodcastIDs)
    }

    func prepareEpisodeSearchIndex() async throws {
        try await base.prepareEpisodeSearchIndex()
    }

    func setEpisodeSearchIndexRebuildHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) async {
        await base.setEpisodeSearchIndexRebuildHandler(handler)
    }

    func searchEpisodes(
        _ request: EpisodeSearchIndexRequest
    ) async throws -> [EpisodeSearchIndexHit] {
        try await base.searchEpisodes(request)
    }

    func replaceEpisodeTranscriptSearchDocument(
        _ document: EpisodeSearchTranscriptDocument
    ) async throws {
        try await base.replaceEpisodeTranscriptSearchDocument(document)
    }

    func removeEpisodeTranscriptSearchDocument(
        episodeID: String
    ) async throws {
        try await base.removeEpisodeTranscriptSearchDocument(episodeID: episodeID)
    }

    func reconcileEpisodeTranscriptSearchDocuments(
        retaining episodeIDs: Set<String>
    ) async throws {
        try await base.reconcileEpisodeTranscriptSearchDocuments(retaining: episodeIDs)
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {
        if await gates.isUpsertArmed {
            await gates.reachedUpsert.release()
            await gates.upsertRelease.wait()
        }
        try await base.upsertCache(from: snapshot, refreshedAt: refreshedAt)
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {
        try await base.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
    }

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {
        try await base.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
    }

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {
        try await base.insertRefreshLog(log, prunedTo: retentionLimit)
    }

    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators? {
        try await base.feedValidators(forPodcastID: podcastID)
    }

    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws {
        try await base.updateFeedValidators(validators, forPodcastID: podcastID)
    }

    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot] {
        try await base.cachedEpisodes(forPodcastID: podcastID)
    }

    func deleteEpisodes(episodeIDs: [String]) async throws {
        try await base.deleteEpisodes(episodeIDs: episodeIDs)
    }

    func deleteCache(forPodcastID podcastID: String) async throws {
        try await base.deleteCache(forPodcastID: podcastID)
    }

    func deleteAllLocalCache() async throws {
        if await gates.isDeleteAllArmed {
            await gates.reachedDeleteAll.release()
            await gates.deleteAllRelease.wait()
        }
        try await base.deleteAllLocalCache()
    }

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws {
        try await base.replaceNotificationFeedHealth(records)
    }

    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth] {
        try await base.notificationFeedHealthByFeedURL()
    }

    func hasCompletedLegacyImport() async throws -> Bool {
        try await base.hasCompletedLegacyImport()
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {
        try await base.importLegacyCache(podcasts: podcasts, episodes: episodes, refreshLogs: refreshLogs)
    }
}
