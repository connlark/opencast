import Foundation
import OpenCastCore
import OpenCastTranscription
import SQLite3
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode search index upgrade regression")
struct EpisodeSearchIndexUpgradeRegressionTests {
    private static let feedURL = "https://example.com/upgrade-feed.xml"

    @Test("An installed schema-5 cache rebuilds exactly once and stays ready")
    func installedSchema5UpgradeRebuildsExactlyOnce() async throws {
        let databaseURL = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let request = EpisodeSearchIndexRequest(
            query: "orchard midnight",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )

        let installedStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await seedCorpus(in: installedStore)
        try await installedStore.prepareEpisodeSearchIndex()
        let expectedIDs = try await installedStore.searchEpisodes(request)
            .map(\.episodeID)
        try #require(!expectedIDs.isEmpty)
        #expect(try readStoredContentVersion(databaseURL: databaseURL)
                == String(SQLiteEpisodeSearchIndex.contentVersion))

        try downgradeToInstalledSchema5(contentVersion: "11", databaseURL: databaseURL)

        let upgradeStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        #expect(
            try await upgradeStore.episodeSearchIndexStateDescription()
                == "needsRebuild"
        )
        await #expect(throws: EpisodeSearchIndexError.self) {
            _ = try await upgradeStore.searchEpisodes(request)
        }
        try await upgradeStore.prepareEpisodeSearchIndex()
        #expect(
            try await upgradeStore.episodeSearchIndexStateDescription()
                == "ready"
        )
        #expect(try readStoredContentVersion(databaseURL: databaseURL)
                == String(SQLiteEpisodeSearchIndex.contentVersion))
        #expect(
            try await upgradeStore.searchEpisodes(request).map(\.episodeID)
                == expectedIDs
        )

        let relaunchStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        #expect(
            try await relaunchStore.episodeSearchIndexStateDescription()
                == "validating"
        )
        let changesBeforePreparation = try await relaunchStore.totalRowChangeCount()
        try await relaunchStore.prepareEpisodeSearchIndex()
        let changesAfterPreparation = try await relaunchStore.totalRowChangeCount()
        #expect(
            try await relaunchStore.episodeSearchIndexStateDescription()
                == "ready"
        )
        #expect(changesAfterPreparation - changesBeforePreparation == 0)
        #expect(
            try await relaunchStore.searchEpisodes(request).map(\.episodeID)
                == expectedIDs
        )
    }

    @Test("An interrupted upgrade rebuild converges on the next launch")
    func interruptedUpgradeRebuildConvergesOnRelaunch() async throws {
        let databaseURL = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let request = EpisodeSearchIndexRequest(
            query: "orchard midnight",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )

        let installedStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await seedCorpus(in: installedStore)
        try await installedStore.prepareEpisodeSearchIndex()
        let expectedIDs = try await installedStore.searchEpisodes(request)
            .map(\.episodeID)
        try downgradeToInstalledSchema5(contentVersion: "10", databaseURL: databaseURL)

        let rebuildCheckpoint = EpisodeSearchRebuildCheckpoint()
        let interruptedStore = SQLiteLocalLibraryCacheStore(
            databaseURL: databaseURL,
            episodeSearchRebuildBatchSize: 1,
            episodeSearchRebuildCheckpoint: {
                await rebuildCheckpoint.reach()
            }
        )
        let rebuildTask = Task {
            try await interruptedStore.prepareEpisodeSearchIndex()
        }
        await rebuildCheckpoint.waitUntilReached()
        #expect(
            try await interruptedStore.episodeSearchIndexStateDescription()
                == "rebuilding"
        )
        rebuildTask.cancel()
        await rebuildCheckpoint.release()
        await #expect(throws: CancellationError.self) {
            try await rebuildTask.value
        }

        let relaunchStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        #expect(
            try await relaunchStore.episodeSearchIndexStateDescription()
                == "needsRebuild"
        )
        try await relaunchStore.prepareEpisodeSearchIndex()
        #expect(try readStoredContentVersion(databaseURL: databaseURL)
                == String(SQLiteEpisodeSearchIndex.contentVersion))
        #expect(
            try await relaunchStore.searchEpisodes(request).map(\.episodeID)
                == expectedIDs
        )
    }

    @Test("The upgrade launch composition converges with transcripts and stays quiet")
    func upgradeLaunchCompositionWithTranscriptsConverges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let databaseURL = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let transcriptDirectory = FileManager.default.temporaryDirectory
            .appending(path: "UpgradeTranscripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transcriptDirectory) }
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: transcriptDirectory)

        let installedStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await seedCorpus(in: installedStore)
        try await installedStore.prepareEpisodeSearchIndex()
        try insertCompletedTranscript(
            episodeID: "upgrade-3",
            podcastID: Self.feedURL,
            text: "A heliopause boundary crossing survives the upgrade.",
            fileStore: fileStore,
            modelContext: context
        )
        let installedTranscriptions = EpisodeTranscriptionStore(fileStore: fileStore)
        installedTranscriptions.episodeSearchIndexStore = installedStore
        installedTranscriptions.load(modelContext: context)
        await installedTranscriptions.waitForEpisodeSearchIndexSync()
        let transcriptRequest = EpisodeSearchIndexRequest(
            query: "heliopause boundary",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )
        #expect(
            try await installedStore.searchEpisodes(transcriptRequest)
                .map(\.episodeID) == ["upgrade-3"]
        )
        try downgradeToInstalledSchema5(contentVersion: "10", databaseURL: databaseURL)

        // The app's launch order: the index store is assigned before load, and preparation
        // races reconciliation in small batches.
        let launchStore = SQLiteLocalLibraryCacheStore(
            databaseURL: databaseURL,
            episodeSearchRebuildBatchSize: 5
        )
        let launchTranscriptions = EpisodeTranscriptionStore(fileStore: fileStore)
        launchTranscriptions.episodeSearchIndexStore = launchStore
        let libraryPreparation = Task {
            try? await launchStore.prepareEpisodeSearchIndex()
        }
        launchTranscriptions.load(modelContext: context)
        await libraryPreparation.value
        await launchTranscriptions.waitForEpisodeSearchIndexSync()

        // The rebuild's follow-up reconciliation lands after a task hop, so poll for it.
        var transcriptRecovered = false
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            await launchTranscriptions.waitForEpisodeSearchIndexSync()
            if let hits = try? await launchStore.searchEpisodes(transcriptRequest),
               hits.map(\.episodeID) == ["upgrade-3"] {
                transcriptRecovered = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(transcriptRecovered)
        #expect(
            try await launchStore.episodeSearchIndexStateDescription()
                == "ready"
        )
        #expect(try readStoredContentVersion(databaseURL: databaseURL)
                == String(SQLiteEpisodeSearchIndex.contentVersion))

        let changesAfterConvergence = try await launchStore.totalRowChangeCount()
        try? await Task.sleep(for: .milliseconds(300))
        await launchTranscriptions.waitForEpisodeSearchIndexSync()
        let changesAfterQuietWindow = try await launchStore.totalRowChangeCount()
        #expect(changesAfterQuietWindow - changesAfterConvergence == 0)
        #expect(
            try await launchStore.episodeSearchIndexStateDescription()
                == "ready"
        )

        let relaunchStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let relaunchTranscriptions = EpisodeTranscriptionStore(fileStore: fileStore)
        relaunchTranscriptions.episodeSearchIndexStore = relaunchStore
        let changesBeforeRelaunchPreparation = try await relaunchStore.totalRowChangeCount()
        let relaunchPreparation = Task {
            try? await relaunchStore.prepareEpisodeSearchIndex()
        }
        relaunchTranscriptions.load(modelContext: context)
        await relaunchPreparation.value
        await relaunchTranscriptions.waitForEpisodeSearchIndexSync()
        let changesAfterRelaunch = try await relaunchStore.totalRowChangeCount()
        #expect(changesAfterRelaunch - changesBeforeRelaunchPreparation == 0)
        #expect(
            try await relaunchStore.searchEpisodes(transcriptRequest)
                .map(\.episodeID) == ["upgrade-3"]
        )
    }

    // MARK: - Fixtures

    private func downgradeToInstalledSchema5(
        contentVersion: String,
        databaseURL: URL
    ) throws {
        var sql = """
        PRAGMA user_version = 5;
        UPDATE local_cache_meta
        SET value = '\(contentVersion)'
        WHERE key = 'episode_search_content_version';
        DROP TABLE IF EXISTS episode_search_evidence_body;
        ALTER TABLE episode_search_evidence ADD COLUMN body_data BLOB;
        """
        if contentVersion == "10" {
            sql += """

            ALTER TABLE episode_search_evidence DROP COLUMN title_canonical;
            ALTER TABLE episode_search_evidence DROP COLUMN podcast_title_canonical;
            ALTER TABLE episode_transcript_search_segment DROP COLUMN text;
            """
        }
        try execRawSQL(sql, databaseURL: databaseURL)
    }

    private func seedCorpus(in store: SQLiteLocalLibraryCacheStore) async throws {
        let feedURL = try #require(URL(string: Self.feedURL))
        let episodes = (0..<40).map { index in
            Episode(
                id: EpisodeID(rawValue: "upgrade-\(index)"),
                podcastID: PodcastID(rawValue: Self.feedURL),
                podcastTitle: "Upgrade Show",
                title: index == 3
                    ? "The Orchard at Midnight"
                    : "Routine Episode \(index)",
                summary: "Episode \(index) summary",
                showNotesHTML: "<p>Notes for episode \(index): an orchard after midnight.</p>",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                duration: 120,
                audioURL: URL(string: "https://example.com/upgrade-\(index).mp3"),
                artworkURL: nil,
                guid: "upgrade-\(index)"
            )
        }
        try await store.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: Self.feedURL),
                    feedURL: feedURL,
                    title: "Upgrade Show",
                    author: nil,
                    summary: nil,
                    websiteURL: nil,
                    artworkURL: nil
                ),
                episodes: episodes,
                fetchedAt: .now
            ),
            refreshedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
    }

    private func insertCompletedTranscript(
        episodeID: String,
        podcastID: String,
        text: String,
        fileStore: EpisodeTranscriptFileStore,
        modelContext: ModelContext
    ) throws {
        let relativePath = fileStore.relativePath(
            episodeID: episodeID,
            fingerprint: "fixture"
        )
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "fixture-sha",
            modelIdentifier: "openai_whisper-tiny.en",
            modelVersion: "1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: [
                OpenCastTranscriptSegment(
                    id: 1,
                    start: 4,
                    end: 12,
                    text: text,
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                )
            ],
            text: text,
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        modelContext.insert(
            EpisodeTranscriptRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                sourceAudioURL: document.sourceAudioURL,
                sourceFileByteCount: document.sourceFileByteCount,
                sourceFileSHA256: document.sourceFileSHA256,
                modelIdentifier: document.modelIdentifier,
                modelVersion: document.modelVersion,
                modelTreeSHA256: document.modelTreeSHA256,
                state: .completed,
                audioDuration: document.audioDuration,
                completedDuration: document.audioDuration,
                checkpointCount: 0,
                transcriptRelativePath: relativePath
            )
        )
        try modelContext.save()
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SearchUpgradeRegression-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "LocalLibraryCache.sqlite")
    }

    private func readStoredContentVersion(databaseURL: URL) throws -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw LocalLibraryCacheStoreError(
                operation: "test open",
                message: "unable to open database"
            )
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT value FROM local_cache_meta WHERE key = 'episode_search_content_version'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw LocalLibraryCacheStoreError(
                operation: "test prepare",
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: value)
    }

    private func execRawSQL(_ sql: String, databaseURL: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw LocalLibraryCacheStoreError(
                operation: "test open",
                message: "unable to open database"
            )
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalLibraryCacheStoreError(
                operation: "test exec",
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
    }
}

private actor EpisodeSearchRebuildCheckpoint {
    private var isReached = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func reach() async {
        isReached = true
        reachedContinuation?.resume()
        reachedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        guard !isReached else {
            return
        }
        await withCheckedContinuation { continuation in
            reachedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
