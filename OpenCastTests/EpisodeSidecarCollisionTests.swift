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

private actor SingleSnapshotStubFeedService: FeedService {
    private let snapshotsByURL: [String: FeedSnapshot]

    init(snapshotsByURL: [String: FeedSnapshot]) {
        self.snapshotsByURL = snapshotsByURL
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = snapshotsByURL[url.absoluteString] else {
            throw CancellationError()
        }
        return snapshot
    }
}
