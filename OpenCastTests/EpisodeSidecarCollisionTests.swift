import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// The 2026-08-02 Downloads incident matrix: identity migrations that land on
/// an already-populated successor episode ID, and the startup repair for
/// containers the target-blind migrations already corrupted.
@MainActor
@Suite("Episode sidecar collisions")
struct EpisodeSidecarCollisionTests {
    static let oldFeedURL = "https://rss.example.com/feeds.example.com/show.xml"
    static let canonicalFeedURL = "https://feeds.example.com/show.xml"
    static let successorEpisodeID = "successor-episode-id"

    // MARK: - Startup repair (already-corrupted containers)

    @Test("The incident fixture repairs to the file-proven survivor")
    func incidentFixtureRepairsToProvenWinner() async throws {
        let fixture = try DownloadFixture()
        let audioBytes = Data("proven-audio-bytes".utf8)
        let relativePath = try fixture.writeCompletedFile(
            episodeID: Self.successorEpisodeID,
            bytes: audioBytes
        )
        let provenHash = OpenCastSHA256.hash(audioBytes)

        fixture.context.insert(SubscriptionRecord(feedURL: Self.canonicalFeedURL, title: "Show"))
        let provenRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.oldFeedURL,
            sourceAudioURL: "https://cdn.example.com/old.mp3",
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(audioBytes.count),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        provenRecord.sourceFileSHA256 = provenHash
        let staleRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/new.mp3",
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(audioBytes.count),
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        staleRecord.sourceFileSHA256 = "0000aaaa-not-the-file"
        fixture.context.insert(provenRecord)
        fixture.context.insert(staleRecord)
        try fixture.context.save()

        await fixture.store.load(modelContext: fixture.context)

        #expect(fixture.store.lastErrorMessage == nil)
        #expect(fixture.store.records.count == 1)
        let survivor = try #require(fixture.store.records.first)
        #expect(survivor.state == .completed)
        #expect(survivor.sourceFileSHA256 == provenHash)
        #expect(survivor.bytesReceived == Int64(audioBytes.count))
        #expect(survivor.podcastID == Self.canonicalFeedURL)
        #expect(fixture.store.duplicateRepairCount == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.fileStore.fileURL(relativePath: relativePath).path))

        // Idempotent: a second load finds nothing left to repair.
        await fixture.store.load(modelContext: fixture.context)
        #expect(fixture.store.records.count == 1)
        #expect(fixture.store.duplicateRepairCount == 1)
    }

    @Test("A group no record can prove keeps one row marked missing, never a false identity")
    func repairMarksUnprovenGroupMissing() async throws {
        let fixture = try DownloadFixture()
        let relativePath = try fixture.writeCompletedFile(
            episodeID: Self.successorEpisodeID,
            bytes: Data("mystery-bytes-neither-row-hashed".utf8)
        )

        for hash in ["hash-a", "hash-b"] {
            let record = EpisodeDownloadRecord(
                episodeID: Self.successorEpisodeID,
                podcastID: Self.canonicalFeedURL,
                sourceAudioURL: "https://cdn.example.com/file.mp3",
                localRelativePath: relativePath,
                state: .completed,
                bytesReceived: 999
            )
            record.sourceFileSHA256 = hash
            fixture.context.insert(record)
        }
        try fixture.context.save()

        await fixture.store.load(modelContext: fixture.context)

        #expect(fixture.store.records.count == 1)
        let survivor = try #require(fixture.store.records.first)
        #expect(survivor.state == .missing)
        #expect(survivor.sourceFileSHA256.isEmpty)
        #expect(survivor.localRelativePath == relativePath)
        // The unproven file stays claimed until an explicit re-download.
        #expect(FileManager.default.fileExists(atPath: fixture.fileStore.fileURL(relativePath: relativePath).path))
    }

    @Test("A legacy unhashed row consistent with the file outranks a contradicted hashed row")
    func repairKeepsUnhashedRowConsistentWithFile() async throws {
        let fixture = try DownloadFixture()
        let audioBytes = Data("legacy-audio".utf8)
        let relativePath = try fixture.writeCompletedFile(
            episodeID: Self.successorEpisodeID,
            bytes: audioBytes
        )

        let legacyRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(audioBytes.count)
        )
        let contradictedRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(audioBytes.count),
            updatedAt: .now.addingTimeInterval(60)
        )
        contradictedRecord.sourceFileSHA256 = "not-the-file"
        fixture.context.insert(legacyRecord)
        fixture.context.insert(contradictedRecord)
        try fixture.context.save()

        await fixture.store.load(modelContext: fixture.context)

        #expect(fixture.store.records.count == 1)
        let survivor = try #require(fixture.store.records.first)
        #expect(survivor.state == .completed)
        #expect(survivor.sourceFileSHA256.isEmpty)
        #expect(survivor.bytesReceived == Int64(audioBytes.count))
    }

    // MARK: - Collision-aware migration

    @Test("Migration never overwrites a valid successor artifact")
    func migrationKeepsValidSuccessorArtifact() async throws {
        let fixture = try DownloadFixture()
        let oldBytes = Data("old-identity-audio".utf8)
        let newBytes = Data("successor-audio-stays".utf8)
        let oldRelativePath = try fixture.writeCompletedFile(episodeID: "old-episode-id", bytes: oldBytes)
        let newRelativePath = try fixture.writeCompletedFile(
            episodeID: Self.successorEpisodeID,
            bytes: newBytes
        )

        let oldRecord = EpisodeDownloadRecord(
            episodeID: "old-episode-id",
            podcastID: Self.oldFeedURL,
            sourceAudioURL: "https://cdn.example.com/old.mp3",
            localRelativePath: oldRelativePath,
            state: .completed,
            bytesReceived: Int64(oldBytes.count)
        )
        oldRecord.sourceFileSHA256 = OpenCastSHA256.hash(oldBytes)
        let newRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/new.mp3",
            localRelativePath: newRelativePath,
            state: .completed,
            bytesReceived: Int64(newBytes.count)
        )
        newRecord.sourceFileSHA256 = OpenCastSHA256.hash(newBytes)
        fixture.context.insert(oldRecord)
        fixture.context.insert(newRecord)
        try fixture.context.save()

        try fixture.store.migrateEpisodeSidecars(
            from: "old-episode-id",
            to: Self.successorEpisodeID,
            canonicalPodcastID: Self.canonicalFeedURL,
            modelContext: fixture.context
        )
        try fixture.context.save()

        let remaining = try fixture.context.fetch(FetchDescriptor<EpisodeDownloadRecord>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.sourceFileSHA256 == OpenCastSHA256.hash(newBytes))
        let newFileURL = fixture.fileStore.fileURL(relativePath: newRelativePath)
        #expect(try Data(contentsOf: newFileURL) == newBytes)

        // The old identity's audio is unclaimed once the deletion is durable;
        // the next load sweeps it.
        await fixture.store.load(modelContext: fixture.context)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileStore.fileURL(relativePath: oldRelativePath).path))
        #expect(try Data(contentsOf: newFileURL) == newBytes)
        #expect(fixture.store.records.count == 1)
    }

    @Test("Migration replaces an invalid successor with the valid source artifact")
    func migrationMigratesOverInvalidSuccessor() throws {
        let fixture = try DownloadFixture()
        let oldBytes = Data("only-valid-audio".utf8)
        let oldRelativePath = try fixture.writeCompletedFile(episodeID: "old-episode-id", bytes: oldBytes)

        let oldRecord = EpisodeDownloadRecord(
            episodeID: "old-episode-id",
            podcastID: Self.oldFeedURL,
            sourceAudioURL: "https://cdn.example.com/old.mp3",
            localRelativePath: oldRelativePath,
            state: .completed,
            bytesReceived: Int64(oldBytes.count)
        )
        oldRecord.sourceFileSHA256 = OpenCastSHA256.hash(oldBytes)
        // Completed successor row whose file is gone: not a keeper.
        let invalidNewRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/new.mp3",
            localRelativePath: "EpisodeDownloads/\(Self.successorEpisodeID).mp3",
            state: .completed,
            bytesReceived: 12_345
        )
        fixture.context.insert(oldRecord)
        fixture.context.insert(invalidNewRecord)
        try fixture.context.save()

        try fixture.store.migrateEpisodeSidecars(
            from: "old-episode-id",
            to: Self.successorEpisodeID,
            canonicalPodcastID: Self.canonicalFeedURL,
            modelContext: fixture.context
        )
        try fixture.context.save()

        let remaining = try fixture.context.fetch(FetchDescriptor<EpisodeDownloadRecord>())
        #expect(remaining.count == 1)
        let survivor = try #require(remaining.first)
        #expect(survivor.episodeID == Self.successorEpisodeID)
        #expect(survivor.podcastID == Self.canonicalFeedURL)
        #expect(survivor.sourceFileSHA256 == OpenCastSHA256.hash(oldBytes))
        let survivorPath = try #require(survivor.localRelativePath)
        #expect(try Data(contentsOf: fixture.fileStore.fileURL(relativePath: survivorPath)) == oldBytes)
    }

    // MARK: - Transcript and analysis provenance

    @Test("Transcript collision keeps the record matching the surviving download")
    func transcriptCollisionKeepsProvenanceMatch() throws {
        let fixture = try DownloadFixture()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: fixture.baseDirectory)
        let transcriptionStore = EpisodeTranscriptionStore(fileStore: transcriptFileStore)

        let audioBytes = Data("surviving-audio".utf8)
        let provenHash = OpenCastSHA256.hash(audioBytes)
        let downloadPath = try fixture.writeCompletedFile(
            episodeID: Self.successorEpisodeID,
            bytes: audioBytes
        )
        let downloadRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: downloadPath,
            state: .completed,
            bytesReceived: Int64(audioBytes.count)
        )
        downloadRecord.sourceFileSHA256 = provenHash
        fixture.context.insert(downloadRecord)

        let matchingPath = try writeTranscriptDocument(
            fileStore: transcriptFileStore,
            episodeID: Self.successorEpisodeID,
            fingerprint: "matching",
            sourceFileSHA256: provenHash
        )
        let stalePath = try writeTranscriptDocument(
            fileStore: transcriptFileStore,
            episodeID: Self.successorEpisodeID,
            fingerprint: "stale",
            sourceFileSHA256: "stale-audio-hash"
        )
        let matchingRecord = EpisodeTranscriptRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.oldFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            sourceFileSHA256: provenHash,
            state: .completed,
            transcriptRelativePath: matchingPath
        )
        let staleRecord = EpisodeTranscriptRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            sourceFileSHA256: "stale-audio-hash",
            state: .completed,
            transcriptRelativePath: stalePath,
            updatedAt: .now.addingTimeInterval(60)
        )
        fixture.context.insert(matchingRecord)
        fixture.context.insert(staleRecord)
        try fixture.context.save()

        transcriptionStore.load(modelContext: fixture.context)

        #expect(transcriptionStore.records.count == 1)
        let survivor = try #require(transcriptionStore.records.first)
        #expect(survivor.sourceFileSHA256 == provenHash)
        #expect(survivor.state == .completed)
        #expect(transcriptFileStore.documentExists(relativePath: matchingPath))
        #expect(!transcriptFileStore.documentExists(relativePath: stalePath))
        #expect(transcriptionStore.duplicateRepairCount == 1)
    }

    @Test("Analysis collision keeps the record matching the surviving transcript")
    func analysisCollisionKeepsFingerprintMatch() throws {
        let fixture = try DownloadFixture()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: fixture.baseDirectory)
        let analysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: fixture.baseDirectory)
        let analysisStore = EpisodeAdAnalysisStore(fileStore: analysisFileStore)

        let transcriptPath = try writeTranscriptDocument(
            fileStore: transcriptFileStore,
            episodeID: Self.successorEpisodeID,
            fingerprint: "surviving",
            sourceFileSHA256: "surviving-audio-hash"
        )
        let transcriptRecord = EpisodeTranscriptRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            sourceFileSHA256: "surviving-audio-hash",
            state: .completed,
            transcriptRelativePath: transcriptPath
        )
        fixture.context.insert(transcriptRecord)
        let survivingFingerprint = analysisFileStore.transcriptFingerprint(
            for: try transcriptFileStore.read(relativePath: transcriptPath)
        )

        let matchingPath = try writeAnalysisDocument(
            fileStore: analysisFileStore,
            episodeID: Self.successorEpisodeID,
            transcriptFingerprint: survivingFingerprint
        )
        let stalePath = try writeAnalysisDocument(
            fileStore: analysisFileStore,
            episodeID: Self.successorEpisodeID,
            transcriptFingerprint: "stale-fingerprint"
        )
        let matchingRecord = EpisodeAdAnalysisRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.oldFeedURL,
            transcriptFingerprint: survivingFingerprint,
            state: .completed,
            analysisRelativePath: matchingPath
        )
        let staleRecord = EpisodeAdAnalysisRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            transcriptFingerprint: "stale-fingerprint",
            state: .completed,
            analysisRelativePath: stalePath,
            updatedAt: .now.addingTimeInterval(60)
        )
        fixture.context.insert(matchingRecord)
        fixture.context.insert(staleRecord)
        try fixture.context.save()

        analysisStore.load(modelContext: fixture.context)

        #expect(analysisStore.records.count == 1)
        let survivor = try #require(analysisStore.records.first)
        #expect(survivor.transcriptFingerprint == survivingFingerprint)
        #expect(survivor.state == .completed)
        #expect(analysisFileStore.documentExists(relativePath: matchingPath))
        #expect(!analysisFileStore.documentExists(relativePath: stalePath))
        #expect(analysisStore.duplicateRepairCount == 1)
    }

    // MARK: - UI defense

    @Test("The Downloads list model uniques duplicate records deterministically")
    func downloadsListModelUniquesDuplicateRecords() throws {
        let library = LibraryStore(
            feedService: EmptyStubFeedService(),
            localCache: SQLiteLocalLibraryCacheStore.inMemory()
        )
        let completedRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: "EpisodeDownloads/\(Self.successorEpisodeID).mp3",
            state: .completed
        )
        let duplicateRecord = EpisodeDownloadRecord(
            episodeID: Self.successorEpisodeID,
            podcastID: Self.oldFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: "EpisodeDownloads/\(Self.successorEpisodeID).mp3",
            state: .completed,
            updatedAt: .now.addingTimeInterval(-60)
        )
        let failedTwin = EpisodeDownloadRecord(
            episodeID: "other-episode-id",
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/other.mp3",
            state: .failed
        )
        let failedTwinDuplicate = EpisodeDownloadRecord(
            episodeID: "other-episode-id",
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/other.mp3",
            localRelativePath: "EpisodeDownloads/other-episode-id.mp3",
            state: .completed
        )

        let model = DownloadsListModel.make(
            records: [completedRecord, duplicateRecord, failedTwin, failedTwinDuplicate],
            library: library
        )

        let downloadedIDs = model.downloaded.map(\.id)
        #expect(downloadedIDs.count == Set(downloadedIDs).count)
        #expect(model.downloaded.count == 2)
        #expect(model.failed.isEmpty)
        #expect(model.downloaded.contains { $0.record === completedRecord })
        #expect(model.downloaded.contains { $0.record === failedTwinDuplicate })
        // Determinism: the same rows in any order render the same list.
        let reversed = DownloadsListModel.make(
            records: [failedTwinDuplicate, failedTwin, duplicateRecord, completedRecord],
            library: library
        )
        #expect(reversed.downloaded.map(\.id).sorted() == downloadedIDs.sorted())
        #expect(reversed.downloaded.contains { $0.record === completedRecord })
    }

    // MARK: - Moved-feed trigger end to end

    @Test("Moved-feed migration with populated sidecars converges to one coherent set")
    func movedFeedMigrationWithPopulatedSidecars() async throws {
        let fixture = try DownloadFixture()
        let oldFeedSnapshot = makeSnapshot(feedURL: Self.oldFeedURL, guid: "stable-guid")
        let newFeedSnapshot = makeSnapshot(feedURL: Self.canonicalFeedURL, guid: "stable-guid")
        let oldEpisodeID = oldFeedSnapshot.episodes[0].id.rawValue
        let newEpisodeID = newFeedSnapshot.episodes[0].id.rawValue
        #expect(oldEpisodeID != newEpisodeID)

        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: oldFeedSnapshot, refreshedAt: .now)
        let library = LibraryStore(
            feedService: SingleSnapshotStubFeedService(
                snapshotsByURL: [Self.canonicalFeedURL: newFeedSnapshot]
            ),
            localCache: cache
        )
        library.episodeSidecarMigrators = [fixture.store]
        fixture.context.insert(SubscriptionRecord(feedURL: Self.oldFeedURL, title: "Show"))

        let oldBytes = Data("old-feed-download".utf8)
        let newBytes = Data("new-feed-download".utf8)
        let oldRelativePath = try fixture.writeCompletedFile(episodeID: oldEpisodeID, bytes: oldBytes)
        let newRelativePath = try fixture.writeCompletedFile(episodeID: newEpisodeID, bytes: newBytes)
        let oldDownload = EpisodeDownloadRecord(
            episodeID: oldEpisodeID,
            podcastID: Self.oldFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: oldRelativePath,
            state: .completed,
            bytesReceived: Int64(oldBytes.count)
        )
        oldDownload.sourceFileSHA256 = OpenCastSHA256.hash(oldBytes)
        let newDownload = EpisodeDownloadRecord(
            episodeID: newEpisodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            localRelativePath: newRelativePath,
            state: .completed,
            bytesReceived: Int64(newBytes.count)
        )
        newDownload.sourceFileSHA256 = OpenCastSHA256.hash(newBytes)
        fixture.context.insert(oldDownload)
        fixture.context.insert(newDownload)
        fixture.context.insert(
            AdFreePassQueueItemRecord(
                episodeID: oldEpisodeID,
                podcastID: Self.oldFeedURL,
                originRawValue: "manual",
                sequence: 1
            )
        )
        fixture.context.insert(
            AdFreePassQueueItemRecord(
                episodeID: newEpisodeID,
                podcastID: Self.canonicalFeedURL,
                originRawValue: "manual",
                sequence: 2
            )
        )
        try fixture.context.save()

        try await library.migrateSubscription(
            from: Self.oldFeedURL,
            toFeedURL: URL(string: Self.canonicalFeedURL)!,
            modelContext: fixture.context
        )

        let downloadRecords = try fixture.context.fetch(FetchDescriptor<EpisodeDownloadRecord>())
        #expect(downloadRecords.count == 1)
        let survivingDownload = try #require(downloadRecords.first)
        #expect(survivingDownload.episodeID == newEpisodeID)
        #expect(survivingDownload.sourceFileSHA256 == OpenCastSHA256.hash(newBytes))
        #expect(try Data(contentsOf: fixture.fileStore.fileURL(relativePath: newRelativePath)) == newBytes)

        let queueItems = try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(queueItems.map(\.episodeID) == [newEpisodeID])

        let subscriptions = try fixture.context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [Self.canonicalFeedURL])
    }

    @Test("Moved-feed migration re-keys playlist items, drops per-playlist collisions, and writes no playlist tombstone")
    func movedFeedMigrationRekeysPlaylistItemsPerPlaylist() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let oldFeedSnapshot = makeSnapshot(feedURL: Self.oldFeedURL, guid: "stable-guid")
        let newFeedSnapshot = makeSnapshot(feedURL: Self.canonicalFeedURL, guid: "stable-guid")
        let oldEpisodeID = oldFeedSnapshot.episodes[0].id.rawValue
        let newEpisodeID = newFeedSnapshot.episodes[0].id.rawValue
        #expect(oldEpisodeID != newEpisodeID)

        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: oldFeedSnapshot, refreshedAt: .now)
        let library = LibraryStore(
            feedService: SingleSnapshotStubFeedService(
                snapshotsByURL: [Self.canonicalFeedURL: newFeedSnapshot]
            ),
            localCache: cache
        )
        context.insert(SubscriptionRecord(feedURL: Self.oldFeedURL, title: "Show"))

        let itemUpdatedAt = Date(timeIntervalSince1970: 1_700_000_200)
        context.insert(PlaylistRecord(playlistID: "departed-only-playlist", name: "Departed Only"))
        context.insert(PlaylistRecord(playlistID: "both-episodes-playlist", name: "Both Episodes"))
        context.insert(
            PlaylistItemRecord(
                itemID: "rekeyed-item",
                playlistID: "departed-only-playlist",
                episodeID: oldEpisodeID,
                podcastID: Self.oldFeedURL,
                sortKey: "i",
                addedAt: itemUpdatedAt,
                updatedAt: itemUpdatedAt,
                episodeTitle: "Episode One",
                podcastTitle: "Show"
            )
        )
        context.insert(
            PlaylistItemRecord(
                itemID: "departed-item",
                playlistID: "both-episodes-playlist",
                episodeID: oldEpisodeID,
                podcastID: Self.oldFeedURL,
                sortKey: "9",
                addedAt: itemUpdatedAt,
                updatedAt: itemUpdatedAt,
                episodeTitle: "Episode One",
                podcastTitle: "Show"
            )
        )
        context.insert(
            PlaylistItemRecord(
                itemID: "successor-item",
                playlistID: "both-episodes-playlist",
                episodeID: newEpisodeID,
                podcastID: Self.canonicalFeedURL,
                sortKey: "r",
                addedAt: itemUpdatedAt,
                updatedAt: itemUpdatedAt,
                episodeTitle: "Episode One",
                podcastTitle: "Show"
            )
        )
        context.insert(
            AdFreePassQueueItemRecord(
                episodeID: oldEpisodeID,
                podcastID: Self.oldFeedURL,
                originRawValue: "manual",
                sequence: 1
            )
        )
        context.insert(
            AdFreePassQueueItemRecord(
                episodeID: newEpisodeID,
                podcastID: Self.canonicalFeedURL,
                originRawValue: "manual",
                sequence: 2
            )
        )
        try context.save()

        try await library.migrateSubscription(
            from: Self.oldFeedURL,
            toFeedURL: URL(string: Self.canonicalFeedURL)!,
            modelContext: context
        )

        let playlistItems = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(playlistItems.map(\.itemID).sorted() == ["rekeyed-item", "successor-item"])

        let rekeyed = try #require(playlistItems.first(where: { $0.itemID == "rekeyed-item" }))
        #expect(rekeyed.playlistID == "departed-only-playlist")
        #expect(rekeyed.episodeID == newEpisodeID)
        #expect(rekeyed.podcastID == Self.canonicalFeedURL)
        #expect(rekeyed.sortKey == "i")
        #expect(rekeyed.updatedAt == itemUpdatedAt)

        let successor = try #require(playlistItems.first(where: { $0.itemID == "successor-item" }))
        #expect(successor.playlistID == "both-episodes-playlist")
        #expect(successor.episodeID == newEpisodeID)
        #expect(successor.podcastID == Self.canonicalFeedURL)
        #expect(successor.sortKey == "r")

        let queueItems = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(queueItems.map(\.episodeID) == [newEpisodeID])

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [Self.canonicalFeedURL])

        // The re-keyed row keeps its addedAt, so a tombstone for the departed
        // pair would delete this membership if the row ever returned to it.
        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).isEmpty)

        let repairResult = try SyncDuplicateRepairer.repair(modelContext: context, save: { try $0.save() })

        let repairedItems = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(repairedItems.map(\.itemID).sorted() == ["rekeyed-item", "successor-item"])
        #expect(repairedItems.first(where: { $0.itemID == "rekeyed-item" })?.episodeID == newEpisodeID)
        #expect(repairResult.tombstonedPlaylistItemRecordsDeleted == 0)
        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).isEmpty)
    }

    @Test("A playlist item re-keyed away and back keeps its membership and its addedAt")
    func playlistItemRekeyedAwayAndBackSurvivesRepair() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let addedAt = Date(timeIntervalSince1970: 1_700_000_200)
        context.insert(PlaylistRecord(playlistID: "round-trip-playlist", name: "Round Trip"))
        context.insert(
            makePlaylistItem(
                itemID: "round-trip-item",
                playlistID: "round-trip-playlist",
                episodeID: "episode-at-first-url",
                sortKey: "m",
                addedAt: addedAt
            )
        )
        try context.save()

        try rekeyPlaylistEpisode(
            from: "episode-at-first-url",
            to: "episode-at-second-url",
            canonicalFeedURL: "https://feeds.example.com/moved.xml",
            modelContext: context
        )
        try context.save()
        try rekeyPlaylistEpisode(
            from: "episode-at-second-url",
            to: "episode-at-first-url",
            canonicalFeedURL: "https://feeds.example.com/show.xml",
            modelContext: context
        )
        try context.save()

        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).isEmpty)
        let repairResult = try SyncDuplicateRepairer.repair(modelContext: context, save: { try $0.save() })
        #expect(repairResult.tombstonedPlaylistItemRecordsDeleted == 0)

        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.itemID == "round-trip-item")
        #expect(item.playlistID == "round-trip-playlist")
        #expect(item.episodeID == "episode-at-first-url")
        #expect(item.podcastID == "https://feeds.example.com/show.xml")
        #expect(item.sortKey == "m")
        #expect(item.addedAt == addedAt)
    }

    @Test("A successor an item tombstone shadows does not cover the departed row, which is re-keyed and survives repair")
    func rekeyIgnoresTombstonedSuccessor() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let successorAddedAt = Date(timeIntervalSince1970: 1_700_000_200)
        context.insert(PlaylistRecord(playlistID: "re-add-playlist", name: "Re-add"))
        // The successor was in the playlist, then removed (tombstone), and the
        // user added the episode again under its departed identity afterwards.
        context.insert(
            makePlaylistItem(
                itemID: "stale-successor",
                playlistID: "re-add-playlist",
                episodeID: "successor-episode",
                sortKey: "a",
                addedAt: successorAddedAt
            )
        )
        context.insert(
            PlaylistTombstoneRecord(
                playlistID: "re-add-playlist",
                episodeID: "successor-episode",
                deletedAt: successorAddedAt.addingTimeInterval(60)
            )
        )
        context.insert(
            makePlaylistItem(
                itemID: "re-added-as-departed",
                playlistID: "re-add-playlist",
                episodeID: "departed-episode",
                sortKey: "m",
                addedAt: successorAddedAt.addingTimeInterval(120)
            )
        )
        try context.save()

        try rekeyPlaylistEpisode(
            from: "departed-episode",
            to: "successor-episode",
            canonicalFeedURL: Self.canonicalFeedURL,
            modelContext: context
        )
        try context.save()

        let rekeyed = try #require(
            try context.fetch(FetchDescriptor<PlaylistItemRecord>()).first { $0.itemID == "re-added-as-departed" }
        )
        #expect(rekeyed.episodeID == "successor-episode")
        #expect(rekeyed.addedAt == successorAddedAt.addingTimeInterval(120))

        let repairResult = try SyncDuplicateRepairer.repair(modelContext: context, save: { try $0.save() })
        #expect(repairResult.tombstonedPlaylistItemRecordsDeleted == 1)
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.map(\.itemID) == ["re-added-as-departed"])
        #expect(items.first?.episodeID == "successor-episode")
    }

    @Test("A re-key deletes a departed playlist item an existing removal tombstone shadows")
    func rekeyDeletesTombstoneShadowedPlaylistItem() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let addedAt = Date(timeIntervalSince1970: 1_700_000_200)
        context.insert(PlaylistRecord(playlistID: "removed-from-playlist", name: "Removed From"))
        context.insert(PlaylistRecord(playlistID: "still-holding-playlist", name: "Still Holding"))
        context.insert(
            makePlaylistItem(
                itemID: "removed-item",
                playlistID: "removed-from-playlist",
                episodeID: "departed-episode",
                sortKey: "m",
                addedAt: addedAt
            )
        )
        context.insert(
            makePlaylistItem(
                itemID: "kept-item",
                playlistID: "still-holding-playlist",
                episodeID: "departed-episode",
                sortKey: "m",
                addedAt: addedAt
            )
        )
        context.insert(
            PlaylistTombstoneRecord(
                playlistID: "removed-from-playlist",
                episodeID: "departed-episode",
                deletedAt: addedAt.addingTimeInterval(60)
            )
        )
        try context.save()

        try rekeyPlaylistEpisode(
            from: "departed-episode",
            to: "successor-episode",
            canonicalFeedURL: Self.canonicalFeedURL,
            modelContext: context
        )
        try context.save()

        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.map(\.itemID) == ["kept-item"])
        #expect(items.first?.episodeID == "successor-episode")
        #expect(!items.contains { $0.playlistID == "removed-from-playlist" })
        let tombstones = try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>())
        #expect(tombstones.map { "\($0.playlistID)/\($0.episodeID ?? "-")" } == [
            "removed-from-playlist/departed-episode"
        ])
    }

    @Test("A re-key keeps the departed twin added last, whatever the store order or its dedupeUUID")
    func rekeyKeepsNewestAddedTwin() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let addedAt = Date(timeIntervalSince1970: 1_700_000_200)
        context.insert(PlaylistRecord(playlistID: "twin-playlist", name: "Twins"))
        // The store's item order (sortKey first) lists the kept twin last, and
        // its dedupeUUID is the larger one: only its newer add picks it.
        context.insert(
            makePlaylistItem(
                itemID: "later-sorted-twin",
                playlistID: "twin-playlist",
                episodeID: "departed-episode",
                sortKey: "z",
                addedAt: addedAt.addingTimeInterval(60),
                dedupeUUID: "FFFFFFFF-0000-0000-0000-000000000001"
            )
        )
        context.insert(
            makePlaylistItem(
                itemID: "earlier-sorted-twin",
                playlistID: "twin-playlist",
                episodeID: "departed-episode",
                sortKey: "a",
                addedAt: addedAt,
                dedupeUUID: "00000000-0000-0000-0000-000000000001"
            )
        )
        try context.save()

        try rekeyPlaylistEpisode(
            from: "departed-episode",
            to: "successor-episode",
            canonicalFeedURL: Self.canonicalFeedURL,
            modelContext: context
        )
        try context.save()

        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.map(\.itemID) == ["later-sorted-twin"])
        let survivor = try #require(items.first)
        #expect(survivor.episodeID == "successor-episode")
        #expect(survivor.podcastID == Self.canonicalFeedURL)
        #expect(survivor.sortKey == "z")
        #expect(survivor.dedupeUUID == "FFFFFFFF-0000-0000-0000-000000000001")
        #expect(survivor.addedAt == addedAt.addingTimeInterval(60))
        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).isEmpty)

        _ = try SyncDuplicateRepairer.repair(modelContext: context, save: { try $0.save() })
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).map(\.itemID) == ["later-sorted-twin"])
    }

    // MARK: - Helpers

    @MainActor
    private struct DownloadFixture {
        let baseDirectory: URL
        let fileStore: EpisodeDownloadFileStore
        let store: DownloadStore
        let context: ModelContext

        init() throws {
            baseDirectory = FileManager.default.temporaryDirectory
                .appending(path: "OpenCastSidecarCollisionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            fileStore = EpisodeDownloadFileStore(baseDirectory: baseDirectory)
            store = DownloadStore(fileStore: fileStore)
            let container = try OpenCastModelContainerFactory.make(inMemory: true)
            context = ModelContext(container)
        }

        func writeCompletedFile(episodeID: String, bytes: Data) throws -> String {
            try fileStore.prepareDownloadsDirectory()
            let relativePath = fileStore.relativePath(
                episodeID: episodeID,
                sourceAudioURL: URL(string: "https://cdn.example.com/file.mp3")!
            )
            try bytes.write(to: fileStore.fileURL(relativePath: relativePath))
            return relativePath
        }
    }

    private func makePlaylistItem(
        itemID: String,
        playlistID: String,
        episodeID: String,
        sortKey: String,
        addedAt: Date,
        dedupeUUID: String = UUID().uuidString
    ) -> PlaylistItemRecord {
        PlaylistItemRecord(
            itemID: itemID,
            playlistID: playlistID,
            episodeID: episodeID,
            podcastID: Self.oldFeedURL,
            sortKey: sortKey,
            addedAt: addedAt,
            updatedAt: addedAt,
            episodeTitle: "Episode One",
            podcastTitle: "Show",
            dedupeUUID: dedupeUUID
        )
    }

    private func rekeyPlaylistEpisode(
        from departedEpisodeID: String,
        to successorEpisodeID: String,
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        try EpisodeIdentityMigrationApplier.apply(
            [
                EpisodeIdentityReconciler.Match(
                    departedEpisodeID: departedEpisodeID,
                    successorEpisodeID: successorEpisodeID
                )
            ],
            canonicalFeedURL: canonicalFeedURL,
            sidecarMigrators: [],
            modelContext: modelContext
        )
    }

    private func writeTranscriptDocument(
        fileStore: EpisodeTranscriptFileStore,
        episodeID: String,
        fingerprint: String,
        sourceFileSHA256: String
    ) throws -> String {
        let relativePath = fileStore.relativePath(episodeID: episodeID, fingerprint: fingerprint)
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: episodeID,
            podcastID: Self.canonicalFeedURL,
            sourceAudioURL: "https://cdn.example.com/file.mp3",
            sourceFileByteCount: 0,
            sourceFileSHA256: sourceFileSHA256,
            modelIdentifier: "test-model",
            modelVersion: "1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: [
                OpenCastTranscriptSegment(
                    id: 0,
                    start: 0,
                    end: 5,
                    text: "hello \(fingerprint)",
                    avgLogProbability: 0,
                    noSpeechProbability: 0
                )
            ],
            text: "hello \(fingerprint)",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        return relativePath
    }

    private func writeAnalysisDocument(
        fileStore: EpisodeAdAnalysisFileStore,
        episodeID: String,
        transcriptFingerprint: String
    ) throws -> String {
        let relativePath = fileStore.relativePath(
            episodeID: episodeID,
            transcriptFingerprint: transcriptFingerprint
        )
        let document = EpisodeAdAnalysisDocument(
            schemaVersion: 1,
            episodeID: episodeID,
            podcastID: Self.canonicalFeedURL,
            requestID: UUID().uuidString,
            transcriptFingerprint: transcriptFingerprint,
            transcriptUpdatedAt: .now,
            transcriptSegmentCount: 1,
            model: "test-model",
            policy: "test-policy",
            spans: [],
            warnings: [],
            usage: nil,
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        return relativePath
    }

    private func makeSnapshot(feedURL: String, guid: String) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let audioURL = URL(string: "https://cdn.example.com/file.mp3")
        return FeedSnapshot(
            podcast: Podcast(
                id: URLCanonicalizer.podcastID(for: url),
                feedURL: url,
                title: "Show"
            ),
            episodes: [
                Episode(
                    id: EpisodeIdentity.makeID(
                        feedURL: url,
                        guid: guid,
                        audioURL: audioURL,
                        title: "Episode One",
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
                    ),
                    podcastID: URLCanonicalizer.podcastID(for: url),
                    podcastTitle: "Show",
                    title: "Episode One",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    duration: 120,
                    audioURL: audioURL,
                    guid: guid
                )
            ]
        )
    }
}

private struct EmptyStubFeedService: FeedService {
    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        throw CancellationError()
    }
}
