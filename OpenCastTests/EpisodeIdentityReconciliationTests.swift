import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode identity reconciliation")
struct EpisodeIdentityReconciliationTests {
    static let feedURL = "https://example.com/reconcile.xml"
    static let dateOne = Date(timeIntervalSince1970: 1_700_000_100)
    static let dateTwo = Date(timeIntervalSince1970: 1_700_000_200)

    @Test("Publisher-added GUIDs migrate progress, tombstone old IDs, and drop stale rows")
    func guidAddedMigratesProgress() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne),
            makeEpisode(guid: nil, audio: "https://example.com/audio/two.mp3", title: "Two", date: Self.dateTwo)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: "guid-one", audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne),
            makeEpisode(guid: "guid-two", audio: "https://example.com/audio/two.mp3", title: "Two", date: Self.dateTwo)
        ])
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)

        let oldID = v1.episodes[0].id.rawValue
        let newID = v2.episodes[0].id.rawValue
        #expect(oldID != newID)
        context.insert(
            EpisodeProgressRecord(episodeID: oldID, podcastID: Self.feedURL, position: 300, duration: 900)
        )
        try context.save()

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.count == 1)
        #expect(progress.first?.episodeID == newID)
        #expect(progress.first?.position == 300)

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(tombstones.count == 2)
        #expect(tombstones.allSatisfy { $0.scope == SyncTombstoneScope.episodeProgress.rawValue })
        #expect(
            Set(tombstones.compactMap(\.episodeID)) == Set(v1.episodes.map(\.id.rawValue))
        )

        #expect(Set(store.episodes.map(\.episodeID)) == Set(v2.episodes.map(\.id.rawValue)))
    }

    @Test("A CDN move with stable GUIDs changes nothing")
    func stableGUIDsAreControl() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: "stable", audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: "stable", audio: "https://cdn.example.net/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        #expect(v1.episodes[0].id == v2.episodes[0].id)
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).isEmpty)
        #expect(store.episodes.count == 1)
    }

    @Test("A GUID-less CDN move migrates via the title+date tier")
    func guidlessCDNMoveMigrates() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://old-cdn.example.com/one.mp3", title: "One", date: Self.dateOne)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://new-cdn.example.net/one.mp3", title: "One", date: Self.dateOne)
        ])
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)
        context.insert(
            EpisodeProgressRecord(episodeID: v1.episodes[0].id.rawValue, podcastID: Self.feedURL, position: 120)
        )
        try context.save()

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.map(\.episodeID) == [v2.episodes[0].id.rawValue])
        #expect(store.episodes.map(\.episodeID) == [v2.episodes[0].id.rawValue])
    }

    @Test("A date appearing on an undated episode migrates via the title-only tier")
    func titleOnlyTierHealsDateShifts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: nil, title: "Undated Special", date: nil)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: nil, title: "Undated Special", date: Self.dateOne)
        ])
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)
        context.insert(
            EpisodeProgressRecord(episodeID: v1.episodes[0].id.rawValue, podcastID: Self.feedURL, position: 45)
        )
        try context.save()

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.map(\.episodeID) == [v2.episodes[0].id.rawValue])
    }

    @Test("Ambiguous matches migrate nothing and retain both departed rows")
    func ambiguousMatchesRetainBothRows() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://example.com/audio/a.mp3", title: "Rerun", date: nil),
            makeEpisode(guid: nil, audio: "https://example.com/audio/b.mp3", title: "Rerun", date: nil)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: "rerun-guid", audio: "https://example.com/audio/c.mp3", title: "Rerun", date: Self.dateOne)
        ])
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).isEmpty)
        #expect(store.episodes.count == 3)
    }

    @Test("A removed episode is never folded into a long-stable one at refresh")
    func removedEpisodeIsRetainedAtRefresh() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let stable = makeEpisode(
            guid: "stable-guid",
            audio: "https://example.com/audio/stable.mp3",
            title: "Episode 12",
            date: Self.dateOne
        )
        let removed = makeEpisode(guid: nil, audio: nil, title: "Episode 12", date: nil)
        let v1 = makeSnapshot(episodes: [stable, removed])
        let v2 = makeSnapshot(episodes: [stable])
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).isEmpty)
        #expect(Set(store.episodes.map(\.episodeID)) == Set([stable.id.rawValue, removed.id.rawValue]))
    }

    @Test("Migration merges onto existing successor progress deterministically")
    func migrationMergesOntoExistingSuccessorProgress() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: "guid-one", audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let oldID = v1.episodes[0].id.rawValue
        let newID = v2.episodes[0].id.rawValue
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)
        context.insert(
            EpisodeProgressRecord(
                episodeID: oldID,
                podcastID: Self.feedURL,
                position: 100,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
                dedupeUUID: "bbbbbbbb"
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: newID,
                podcastID: Self.feedURL,
                position: 250,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_500),
                dedupeUUID: "aaaaaaaa"
            )
        )
        try context.save()

        await store.refresh(feedURL: Self.feedURL, modelContext: context)

        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.count == 1)
        #expect(progress.first?.episodeID == newID)
        #expect(progress.first?.position == 250)
        #expect(progress.first?.dedupeUUID == "aaaaaaaa")
    }

    @Test("Migrated progress survives the sync repairer's tombstone pass")
    func migratedProgressSurvivesRepair() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: "guid-one", audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let newID = v2.episodes[0].id.rawValue
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v1, v2]]),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        try await store.subscribe(to: Self.feedURL, modelContext: context)
        context.insert(
            EpisodeProgressRecord(episodeID: v1.episodes[0].id.rawValue, podcastID: Self.feedURL, position: 60)
        )
        try context.save()

        await store.refresh(feedURL: Self.feedURL, modelContext: context)
        let repairResult = try await store.repairSyncDuplicates(modelContext: context)

        #expect(repairResult.tombstonedProgressRecordsDeleted == 0)
        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.map(\.episodeID) == [newID])
        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).count == 1)
    }

    @Test("The manual merge sweep heals an already-duplicated library")
    func manualMergeSweepHealsDuplicatedLibrary() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let v1 = makeSnapshot(episodes: [
            makeEpisode(guid: nil, audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let v2 = makeSnapshot(episodes: [
            makeEpisode(guid: "guid-one", audio: "https://example.com/audio/one.mp3", title: "One", date: Self.dateOne)
        ])
        let oldID = v1.episodes[0].id.rawValue
        let newID = v2.episodes[0].id.rawValue
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        // Seed the duplicated state directly: both catalogs cached, progress
        // stranded on the old ID — the shape a pre-reconciliation library is in.
        try await cache.upsertCache(from: v1, refreshedAt: Date(timeIntervalSince1970: 1_750_000_000))
        try await cache.upsertCache(from: v2, refreshedAt: Date(timeIntervalSince1970: 1_750_000_100))
        let store = LibraryStore(
            feedService: SequencedStubFeedService(snapshots: [Self.feedURL: [v2]]),
            localCache: cache
        )
        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Reconciled Show"))
        context.insert(EpisodeProgressRecord(episodeID: oldID, podcastID: Self.feedURL, position: 500))
        try context.save()
        await store.load(modelContext: context)
        #expect(store.episodes.count == 2)

        let result = try await store.mergeDuplicateEpisodes(modelContext: context)

        #expect(result.feedsProcessed == 1)
        #expect(result.episodesMigrated == 1)
        #expect(result.failedFeedURLs.isEmpty)
        let progress = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progress.map(\.episodeID) == [newID])
        #expect(store.episodes.map(\.episodeID) == [newID])
        #expect(try context.fetch(FetchDescriptor<SyncTombstoneRecord>()).compactMap(\.episodeID) == [oldID])
    }

    // MARK: - Sidecar migration

    @Test("Download records and files re-key onto the successor ID")
    func downloadSidecarMigration() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(fileStore: fileStore)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        let audioData = Data("audio-bytes".utf8)
        let oldRelativePath = fileStore.relativePath(
            episodeID: "old-episode-id",
            sourceAudioURL: URL(string: "https://example.com/audio/file.mp3")!
        )
        try fileStore.prepareDownloadsDirectory()
        try audioData.write(to: fileStore.fileURL(relativePath: oldRelativePath))
        let record = EpisodeDownloadRecord(
            episodeID: "old-episode-id",
            podcastID: "https://example.com/old-feed.xml",
            sourceAudioURL: "https://example.com/audio/file.mp3",
            localRelativePath: oldRelativePath,
            state: .completed,
            bytesReceived: Int64(audioData.count),
            bytesExpected: Int64(audioData.count)
        )
        context.insert(record)
        try context.save()
        await store.load(modelContext: context)

        try store.migrateEpisodeSidecars(
            from: "old-episode-id",
            to: "new-episode-id",
            canonicalPodcastID: Self.feedURL,
            modelContext: context
        )
        try context.save()

        #expect(record.episodeID == "new-episode-id")
        #expect(record.podcastID == Self.feedURL)
        let newRelativePath = try #require(record.localRelativePath)
        #expect(newRelativePath == "EpisodeDownloads/new-episode-id.mp3")
        #expect(FileManager.default.fileExists(atPath: fileStore.fileURL(relativePath: newRelativePath).path))
        #expect(!FileManager.default.fileExists(atPath: fileStore.fileURL(relativePath: oldRelativePath).path))
        // The keyed lookup index must observe the successor identity without
        // a relaunch.
        #expect(store.record(for: "new-episode-id") === record)
        #expect(store.record(for: "old-episode-id") == nil)
    }

    @Test("Transcript records and per-episode directories re-key onto the successor ID")
    func transcriptSidecarMigration() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeTranscriptionStore(fileStore: fileStore)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        let oldRelativePath = fileStore.relativePath(episodeID: "old-episode-id", fingerprint: "fingerprint-1")
        let oldFileURL = fileStore.fileURL(relativePath: oldRelativePath)
        try FileManager.default.createDirectory(
            at: oldFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: oldFileURL)
        let record = EpisodeTranscriptRecord(
            episodeID: "old-episode-id",
            podcastID: "https://example.com/old-feed.xml",
            sourceAudioURL: "https://example.com/audio/file.mp3",
            state: .completed,
            transcriptRelativePath: oldRelativePath
        )
        context.insert(record)
        try context.save()

        try store.migrateEpisodeSidecars(
            from: "old-episode-id",
            to: "new-episode-id",
            canonicalPodcastID: Self.feedURL,
            modelContext: context
        )
        try context.save()

        #expect(record.episodeID == "new-episode-id")
        #expect(record.podcastID == Self.feedURL)
        let newRelativePath = try #require(record.transcriptRelativePath)
        #expect(newRelativePath == fileStore.relativePath(episodeID: "new-episode-id", fingerprint: "fingerprint-1"))
        #expect(FileManager.default.fileExists(atPath: fileStore.fileURL(relativePath: newRelativePath).path))
        #expect(!FileManager.default.fileExists(atPath: oldFileURL.path))
    }

    @Test("Ad-analysis records and per-episode directories re-key onto the successor ID")
    func adAnalysisSidecarMigration() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeAdAnalysisStore(fileStore: fileStore)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        let oldRelativePath = fileStore.relativePath(episodeID: "old-episode-id", transcriptFingerprint: "fp-1")
        let oldFileURL = fileStore.fileURL(relativePath: oldRelativePath)
        try FileManager.default.createDirectory(
            at: oldFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: oldFileURL)
        let record = EpisodeAdAnalysisRecord(
            episodeID: "old-episode-id",
            podcastID: "https://example.com/old-feed.xml",
            state: .completed,
            analysisRelativePath: oldRelativePath
        )
        context.insert(record)
        try context.save()
        store.load(modelContext: context)

        try store.migrateEpisodeSidecars(
            from: "old-episode-id",
            to: "new-episode-id",
            canonicalPodcastID: Self.feedURL,
            modelContext: context
        )
        try context.save()

        #expect(record.episodeID == "new-episode-id")
        #expect(record.podcastID == Self.feedURL)
        let newRelativePath = try #require(record.analysisRelativePath)
        #expect(newRelativePath == fileStore.relativePath(episodeID: "new-episode-id", transcriptFingerprint: "fp-1"))
        #expect(FileManager.default.fileExists(atPath: fileStore.fileURL(relativePath: newRelativePath).path))
        #expect(!FileManager.default.fileExists(atPath: oldFileURL.path))
        #expect(store.record(for: "new-episode-id") === record)
        #expect(store.record(for: "old-episode-id") == nil)
    }

    @Test("Transcript-analysis records and per-episode directories re-key onto the successor ID")
    func transcriptAnalysisSidecarMigration() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeTranscriptAnalysisStore(fileStore: fileStore)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        let oldRelativePath = fileStore.relativePath(episodeID: "old-episode-id", transcriptFingerprint: "fp-1")
        let oldFileURL = fileStore.fileURL(relativePath: oldRelativePath)
        try FileManager.default.createDirectory(
            at: oldFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: oldFileURL)
        let record = EpisodeTranscriptAnalysisRecord(
            episodeID: "old-episode-id",
            podcastID: "https://example.com/old-feed.xml",
            state: .completed,
            analysisRelativePath: oldRelativePath
        )
        context.insert(record)
        try context.save()
        store.load(modelContext: context)

        try store.migrateEpisodeSidecars(
            from: "old-episode-id",
            to: "new-episode-id",
            canonicalPodcastID: Self.feedURL,
            modelContext: context
        )
        try context.save()

        #expect(record.episodeID == "new-episode-id")
        #expect(record.podcastID == Self.feedURL)
        let newRelativePath = try #require(record.analysisRelativePath)
        #expect(newRelativePath == fileStore.relativePath(episodeID: "new-episode-id", transcriptFingerprint: "fp-1"))
        #expect(FileManager.default.fileExists(atPath: fileStore.fileURL(relativePath: newRelativePath).path))
        #expect(!FileManager.default.fileExists(atPath: oldFileURL.path))
        #expect(store.record(for: "new-episode-id") === record)
        #expect(store.record(for: "old-episode-id") == nil)
    }

    // MARK: - Helpers

    private func makeSnapshot(episodes: [Episode]) -> FeedSnapshot {
        FeedSnapshot(
            podcast: Podcast(
                id: URLCanonicalizer.podcastID(for: URL(string: Self.feedURL)!),
                feedURL: URL(string: Self.feedURL)!,
                title: "Reconciled Show"
            ),
            episodes: episodes
        )
    }

    private func makeEpisode(guid: String?, audio: String?, title: String, date: Date?) -> Episode {
        let audioURL = audio.flatMap(URL.init(string:))
        let feedURL = URL(string: Self.feedURL)!
        return Episode(
            id: EpisodeIdentity.makeID(
                feedURL: feedURL,
                guid: guid,
                audioURL: audioURL,
                title: title,
                publishedAt: date
            ),
            podcastID: URLCanonicalizer.podcastID(for: feedURL),
            podcastTitle: "Reconciled Show",
            title: title,
            publishedAt: date,
            duration: 120,
            audioURL: audioURL,
            guid: guid
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastReconciliationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor SequencedStubFeedService: FeedService {
    private var snapshotsByURL: [String: [FeedSnapshot]]

    init(snapshots: [String: [FeedSnapshot]]) {
        snapshotsByURL = snapshots
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let key = url.absoluteString
        guard var snapshots = snapshotsByURL[key], let next = snapshots.first else {
            throw SequencedStubFeedError(message: "No stub snapshot for \(key)")
        }
        if snapshots.count > 1 {
            snapshots.removeFirst()
            snapshotsByURL[key] = snapshots
        }
        return next
    }
}

private struct SequencedStubFeedError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
