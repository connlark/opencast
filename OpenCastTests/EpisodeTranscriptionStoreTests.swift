import Foundation
import OpenCastCore
import OpenCastTranscription
import SQLite3
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcription store")
struct EpisodeTranscriptionStoreTests {
    @Test("Rejects non-completed downloads")
    func rejectsNonCompletedDownloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let store = EpisodeTranscriptionStore(fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory))
        let episode = makeEpisode(episodeID: "not-complete")
        let record = EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            state: .downloading
        )

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(store.lastErrorMessage(for: episode.episodeID) == EpisodeTranscriptionError.downloadNotComplete.localizedDescription)
    }

    @Test("Creates transcript record and document from events")
    func createsTranscriptRecordAndDocumentFromEvents() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let fakeTranscriber = FakeEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-create")
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        let document = try #require(store.document(for: episode.episodeID))
        #expect(transcriptRecord.state == .completed)
        #expect(document.text.contains("hello transcript"))
        #expect(document.segments.map(\.start) == [0, 2])
    }

    @Test("Completed and deleted transcripts reconcile the library search index")
    func transcriptLifecycleReconcilesSearchIndex() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(
            in: temporaryDirectory,
            contents: "audio"
        )
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let episode = makeEpisode(episodeID: "search-index-transcript")
        let feedURL = try #require(URL(string: episode.podcastID))
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: episode.podcastID),
                    feedURL: feedURL,
                    title: episode.podcastTitle,
                    author: nil,
                    summary: nil,
                    websiteURL: nil,
                    artworkURL: nil
                ),
                episodes: [
                    Episode(
                        id: EpisodeID(rawValue: episode.episodeID),
                        podcastID: PodcastID(rawValue: episode.podcastID),
                        podcastTitle: episode.podcastTitle,
                        title: episode.title,
                        summary: episode.summary,
                        showNotesHTML: nil,
                        publishedAt: episode.publishedAt,
                        duration: episode.duration,
                        audioURL: episode.audioURL.flatMap(URL.init(string:)),
                        artworkURL: nil,
                        guid: episode.guid
                    )
                ],
                fetchedAt: .now
            ),
            refreshedAt: .now
        )
        let transcriptionStore = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(
                baseDirectory: temporaryDirectory
            )
        )
        transcriptionStore.episodeSearchIndexStore = cache
        let download = completedDownloadRecord(episode: episode)
        context.insert(download)

        transcriptionStore.startTranscription(
            episode,
            downloadRecord: download,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil {
            transcriptionStore.record(for: episode.episodeID)?.state == .completed
                && !transcriptionStore.hasActiveJob
        })
        await transcriptionStore.waitForEpisodeSearchIndexSync()

        let request = EpisodeSearchIndexRequest(
            query: "hello transcript",
            mode: .fullText,
            activePodcastIDs: [episode.podcastID]
        )
        let indexedHits = try await cache.searchEpisodes(request)
        #expect(indexedHits.first?.episodeID == episode.episodeID)
        #expect(indexedHits.first?.transcriptPassage?.startSeconds == 0)

        transcriptionStore.deleteTranscript(
            episodeID: episode.episodeID,
            modelContext: context
        )
        await transcriptionStore.waitForEpisodeSearchIndexSync()
        #expect(try await cache.searchEpisodes(request).isEmpty)
    }

    @Test("Existing transcript import and identity migration reconcile search")
    func existingTranscriptImportAndMigrationReconcileSearch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(
            baseDirectory: temporaryDirectory
        )
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastID = "https://example.com/feed.xml"
        let oldEpisodeID = "existing-transcript-old"
        let newEpisodeID = "existing-transcript-new"
        let oldEpisode = makeEpisode(episodeID: oldEpisodeID)
        let feedURL = try #require(URL(string: podcastID))
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: podcastID),
                    feedURL: feedURL,
                    title: oldEpisode.podcastTitle,
                    author: nil,
                    summary: nil,
                    websiteURL: nil,
                    artworkURL: nil
                ),
                episodes: [
                    Episode(
                        id: EpisodeID(rawValue: oldEpisodeID),
                        podcastID: PodcastID(rawValue: podcastID),
                        podcastTitle: oldEpisode.podcastTitle,
                        title: oldEpisode.title,
                        summary: oldEpisode.summary,
                        showNotesHTML: nil,
                        publishedAt: oldEpisode.publishedAt,
                        duration: oldEpisode.duration,
                        audioURL: oldEpisode.audioURL.flatMap(URL.init(string:)),
                        artworkURL: nil,
                        guid: oldEpisode.guid
                    )
                ],
                fetchedAt: .now
            ),
            refreshedAt: .now
        )
        try await cache.prepareEpisodeSearchIndex()

        let relativePath = fileStore.relativePath(
            episodeID: oldEpisodeID,
            fingerprint: "existing"
        )
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: oldEpisodeID,
            podcastID: podcastID,
            sourceAudioURL: "https://example.com/existing.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "existing-sha",
            modelIdentifier: "openai_whisper-tiny.en",
            modelVersion: "1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: [
                OpenCastTranscriptSegment(
                    id: 7,
                    start: 12,
                    end: 18,
                    text: "A preexisting heliopause boundary transcript.",
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                )
            ],
            text: "A preexisting heliopause boundary transcript.",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(
            EpisodeTranscriptRecord(
                episodeID: oldEpisodeID,
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
        try context.save()

        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: fileStore
        )
        store.episodeSearchIndexStore = cache
        store.load(modelContext: context)
        await store.waitForEpisodeSearchIndexSync()

        let request = EpisodeSearchIndexRequest(
            query: "heliopause boundary",
            mode: .fullText,
            activePodcastIDs: [podcastID]
        )
        #expect(
            try await cache.searchEpisodes(request).map(\.episodeID)
                == [oldEpisodeID]
        )

        try await cache.deleteEpisodes(episodeIDs: [oldEpisodeID])
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: podcastID),
                    feedURL: feedURL,
                    title: oldEpisode.podcastTitle,
                    author: nil,
                    summary: nil,
                    websiteURL: nil,
                    artworkURL: nil
                ),
                episodes: [
                    Episode(
                        id: EpisodeID(rawValue: newEpisodeID),
                        podcastID: PodcastID(rawValue: podcastID),
                        podcastTitle: oldEpisode.podcastTitle,
                        title: oldEpisode.title,
                        summary: oldEpisode.summary,
                        showNotesHTML: nil,
                        publishedAt: oldEpisode.publishedAt,
                        duration: oldEpisode.duration,
                        audioURL: oldEpisode.audioURL.flatMap(URL.init(string:)),
                        artworkURL: nil,
                        guid: oldEpisode.guid
                    )
                ],
                fetchedAt: .now
            ),
            refreshedAt: .now
        )
        try store.migrateEpisodeSidecars(
            from: oldEpisodeID,
            to: newEpisodeID,
            canonicalPodcastID: podcastID,
            modelContext: context
        )
        try context.save()
        await store.waitForEpisodeSearchIndexSync()

        let migratedDocument = try #require(store.document(for: newEpisodeID))
        #expect(migratedDocument.episodeID == newEpisodeID)
        #expect(migratedDocument.podcastID == podcastID)
        #expect(
            try await cache.searchEpisodes(request).map(\.episodeID)
                == [newEpisodeID]
        )

        try store.deleteTranscripts(
            forPodcastID: podcastID,
            modelContext: context
        )
        await store.waitForEpisodeSearchIndexSync()
        #expect(try await cache.searchEpisodes(request).isEmpty)
    }

    @Test("Assigning the index store before load does not wipe indexed transcripts")
    func assigningIndexStoreBeforeLoadDoesNotWipeIndexedTranscripts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(
            baseDirectory: temporaryDirectory
        )
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let episodeID = "cold-launch-transcript"
        let podcastID = "https://example.com/feed.xml"
        try await seedFeed(
            cache: cache,
            podcastID: podcastID,
            episodeID: episodeID,
            title: "Cold Launch Episode"
        )
        try await cache.prepareEpisodeSearchIndex()
        let document = try insertCompletedTranscript(
            episodeID: episodeID,
            podcastID: podcastID,
            text: "A heliopause boundary crossing recorded on launch day.",
            fileStore: fileStore,
            modelContext: context
        )
        try await cache.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(document)
        )
        let request = EpisodeSearchIndexRequest(
            query: "heliopause boundary",
            mode: .fullText,
            activePodcastIDs: [podcastID]
        )
        #expect(
            try await cache.searchEpisodes(request).map(\.episodeID)
                == [episodeID]
        )

        // Composition order at launch: the index store is assigned before
        // load(modelContext:) can run. That alone must not touch the index.
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: fileStore
        )
        store.episodeSearchIndexStore = cache
        await store.waitForEpisodeSearchIndexSync()
        #expect(
            try await cache.searchEpisodes(request).map(\.episodeID)
                == [episodeID]
        )

        store.load(modelContext: context)
        await store.waitForEpisodeSearchIndexSync()
        #expect(
            try await cache.searchEpisodes(request).map(\.episodeID)
                == [episodeID]
        )
    }

    @Test("A loaded empty record set still reconciles stale transcripts to empty")
    func loadedEmptyRecordSetReconcilesStaleTranscriptsToEmpty() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastID = "https://example.com/feed.xml"
        try await seedFeed(
            cache: cache,
            podcastID: podcastID,
            episodeID: "departed-episode",
            title: "Departed Episode"
        )
        try await cache.prepareEpisodeSearchIndex()
        try await cache.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: "departed-episode",
                podcastID: podcastID,
                version: "stale",
                segments: [
                    EpisodeSearchTranscriptSegment(
                        segmentID: "stale-1",
                        startSeconds: 0,
                        endSeconds: 5,
                        text: "A stale heliopause document with no canonical record."
                    )
                ]
            )
        )
        let request = EpisodeSearchIndexRequest(
            query: "heliopause",
            mode: .fullText,
            activePodcastIDs: [podcastID]
        )
        #expect(try await cache.searchEpisodes(request).isEmpty == false)

        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(
                baseDirectory: temporaryDirectory
            )
        )
        store.episodeSearchIndexStore = cache
        store.load(modelContext: context)
        await store.waitForEpisodeSearchIndexSync()

        #expect(try await cache.searchEpisodes(request).isEmpty)
    }

    @Test("A mid-session index rebuild repopulates transcripts without a relaunch")
    func midSessionRebuildRepopulatesTranscripts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let databaseDirectory = try makeTemporaryDirectory()
        let databaseURL = databaseDirectory.appending(
            path: "LocalLibraryCache.sqlite"
        )
        let fileStore = EpisodeTranscriptFileStore(
            baseDirectory: temporaryDirectory
        )
        let cache = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let episodeID = "rebuild-transcript"
        let podcastID = "https://example.com/feed.xml"
        try await seedFeed(
            cache: cache,
            podcastID: podcastID,
            episodeID: episodeID,
            title: "Rebuild Episode"
        )
        try await cache.prepareEpisodeSearchIndex()
        _ = try insertCompletedTranscript(
            episodeID: episodeID,
            podcastID: podcastID,
            text: "A heliopause boundary crossing survives the rebuild.",
            fileStore: fileStore,
            modelContext: context
        )
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: fileStore
        )
        store.episodeSearchIndexStore = cache
        store.load(modelContext: context)
        await store.waitForEpisodeSearchIndexSync()
        let request = EpisodeSearchIndexRequest(
            query: "heliopause boundary",
            mode: .fullText,
            activePodcastIDs: [podcastID]
        )
        #expect(
            try await cache.searchEpisodes(request).map(\.episodeID)
                == [episodeID]
        )

        // Break a derived table the maintenance path writes so the next
        // refresh marks the index for rebuild, exactly like a mid-session
        // SQLite failure would.
        try execRawSQL(
            "DROP TABLE episode_search_spelling_document",
            databaseURL: databaseURL
        )
        await #expect(throws: (any Error).self) {
            try await seedFeed(
                cache: cache,
                podcastID: podcastID,
                episodeID: episodeID,
                title: "Rebuild Episode Retitled"
            )
        }
        let rolledBack = try await cache.loadLibrary(activePodcastIDs: [podcastID])
        #expect(rolledBack.episodes.first?.title == "Rebuild Episode")
        #expect(
            try await cache.episodeSearchIndexStateDescription()
                == "needsRebuild"
        )
        try execRawSQL(
            """
            CREATE TABLE IF NOT EXISTS episode_search_spelling_document (
              episode_id TEXT NOT NULL,
              source INTEGER NOT NULL,
              terms_data BLOB NOT NULL,
              PRIMARY KEY (episode_id, source)
            ) WITHOUT ROWID
            """,
            databaseURL: databaseURL
        )

        try await cache.prepareEpisodeSearchIndex()

        // The rebuild restored metadata only; the rebuild handler must bring
        // the transcript documents back without a relaunch.
        try await seedFeed(cache: cache, podcastID: podcastID, episodeID: episodeID,
                           title: "Rebuild Episode Retitled")
        let retried = try await cache.loadLibrary(activePodcastIDs: [podcastID])
        #expect(retried.episodes.first?.title == "Rebuild Episode Retitled")
        var transcriptRecovered = false
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let hits = try? await cache.searchEpisodes(request),
               hits.map(\.episodeID) == [episodeID] {
                transcriptRecovered = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(transcriptRecovered)
    }

    @Test("A failed sidecar rewrite does not abort identity migration")
    func failedSidecarRewriteDoesNotAbortIdentityMigration() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(
            baseDirectory: temporaryDirectory
        )
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastID = "https://example.com/feed.xml"
        let oldEpisodeID = "rewrite-fails-old"
        let newEpisodeID = "rewrite-fails-new"
        try await seedFeed(
            cache: cache,
            podcastID: podcastID,
            episodeID: oldEpisodeID,
            title: "Rewrite Episode"
        )
        try await cache.prepareEpisodeSearchIndex()
        _ = try insertCompletedTranscript(
            episodeID: oldEpisodeID,
            podcastID: podcastID,
            text: "A heliopause narration awaiting migration.",
            fileStore: fileStore,
            modelContext: context
        )
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: fileStore
        )
        store.episodeSearchIndexStore = cache
        store.load(modelContext: context)
        await store.waitForEpisodeSearchIndexSync()

        try await cache.deleteEpisodes(episodeIDs: [oldEpisodeID])
        try await seedFeed(
            cache: cache,
            podcastID: podcastID,
            episodeID: newEpisodeID,
            title: "Rewrite Episode"
        )
        // Make the migrated per-episode directory read-only so the sidecar
        // identity rewrite fails while the directory move and reads succeed.
        let oldTranscriptDirectory = temporaryDirectory.appending(
            path: "\(EpisodeTranscriptFileStore.directoryName)/\(fileStore.safeStem(oldEpisodeID))",
            directoryHint: .isDirectory
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: oldTranscriptDirectory.path(percentEncoded: false)
        )
        defer {
            let newTranscriptDirectory = temporaryDirectory.appending(
                path: "\(EpisodeTranscriptFileStore.directoryName)/\(fileStore.safeStem(newEpisodeID))",
                directoryHint: .isDirectory
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: newTranscriptDirectory.path(percentEncoded: false)
            )
        }

        try store.migrateEpisodeSidecars(
            from: oldEpisodeID,
            to: newEpisodeID,
            canonicalPodcastID: podcastID,
            modelContext: context
        )
        try context.save()
        await store.waitForEpisodeSearchIndexSync()

        // The record migrated and reload ran even though the rewrite failed.
        let migratedRecord = try #require(store.record(for: newEpisodeID))
        #expect(migratedRecord.state == .completed)
        #expect(store.record(for: oldEpisodeID) == nil)

        // The sidecar kept its stale embedded identity, so reconciliation
        // must skip it: no searchable ghost under either identity.
        let staleDocument = try #require(store.document(for: newEpisodeID))
        #expect(staleDocument.episodeID == oldEpisodeID)
        #expect(try await cache.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "heliopause narration",
                mode: .fullText,
                activePodcastIDs: [podcastID]
            )
        ).isEmpty)
    }

    private func seedFeed(
        cache: SQLiteLocalLibraryCacheStore,
        podcastID: String,
        episodeID: String,
        title: String
    ) async throws {
        let feedURL = try #require(URL(string: podcastID))
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: podcastID),
                    feedURL: feedURL,
                    title: "Composition Show",
                    author: nil,
                    summary: nil,
                    websiteURL: nil,
                    artworkURL: nil
                ),
                episodes: [
                    Episode(
                        id: EpisodeID(rawValue: episodeID),
                        podcastID: PodcastID(rawValue: podcastID),
                        podcastTitle: "Composition Show",
                        title: title,
                        summary: nil,
                        showNotesHTML: nil,
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
                        duration: 120,
                        audioURL: URL(string: "https://example.com/\(episodeID).mp3"),
                        artworkURL: nil,
                        guid: episodeID
                    )
                ],
                fetchedAt: .now
            ),
            refreshedAt: .now
        )
    }

    @discardableResult
    private func insertCompletedTranscript(
        episodeID: String,
        podcastID: String,
        text: String,
        fileStore: EpisodeTranscriptFileStore,
        modelContext: ModelContext
    ) throws -> EpisodeTranscriptDocument {
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
        return document
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

    @Test("Deleting a transcript sweeps the per-episode directory like the ad-analysis twin")
    func deleteTranscriptSweepsPerEpisodeDirectory() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: fileStore
        )
        let deletedEpisode = makeEpisode(episodeID: "sweep-deleted")
        let keptEpisode = makeEpisode(episodeID: "sweep-kept")
        let deletedRecord = completedDownloadRecord(episode: deletedEpisode)
        let keptRecord = completedDownloadRecord(episode: keptEpisode)
        context.insert(deletedRecord)
        context.insert(keptRecord)

        store.startTranscription(
            deletedEpisode,
            downloadRecord: deletedRecord,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil {
            store.record(for: deletedEpisode.episodeID)?.state == .completed && !store.hasActiveJob
        })
        store.startTranscription(
            keptEpisode,
            downloadRecord: keptRecord,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil {
            store.record(for: keptEpisode.episodeID)?.state == .completed && !store.hasActiveJob
        })

        let deletedEpisodeDirectory = temporaryDirectory
            .appending(path: EpisodeTranscriptFileStore.directoryName, directoryHint: .isDirectory)
            .appending(path: fileStore.safeStem(deletedEpisode.episodeID), directoryHint: .isDirectory)
        let orphanURL = deletedEpisodeDirectory.appending(path: "orphan.json")
        try Data("{}".utf8).write(to: orphanURL, options: .atomic)
        let keptPath = try #require(store.record(for: keptEpisode.episodeID)?.transcriptRelativePath)

        store.deleteTranscript(episodeID: deletedEpisode.episodeID, modelContext: context)

        #expect(store.record(for: deletedEpisode.episodeID) == nil)
        #expect(!FileManager.default.fileExists(atPath: deletedEpisodeDirectory.path))
        #expect(fileStore.documentExists(relativePath: keptPath))
    }

    @Test("Persists requested engine identity and does not reuse it for another engine")
    func persistsRequestedEngineIdentityAndDoesNotReuseItForAnotherEngine() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "apple speech audio")
        let fakeTranscriber = FakeEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        var idleTimerChanges: [Bool] = []
        store.setIdleTimerDisabled = { idleTimerChanges.append($0) }
        let episode = makeEpisode(episodeID: "transcript-apple-speech")
        let record = completedDownloadRecord(episode: episode)
        let appleIdentity = EpisodeTranscriptionModelIdentity(
            modelIdentifier: "apple-speech-transcriber.en_US",
            version: "iOS 26 test",
            treeSHA256: "asset-status-installed-en_US"
        )

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            engine: .appleSpeech,
            modelIdentity: appleIdentity,
            languageCode: "en-US",
            modelContext: context
        )

        // Wait for run teardown too: jobState reports the in-flight progress
        // entry until the run task's cleanup executes.
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed && !store.hasActiveJob
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        let document = try #require(store.document(for: episode.episodeID))
        #expect(fakeTranscriber.lastRequest?.engine == .appleSpeech)
        #expect(fakeTranscriber.lastRequest?.languageCode == "en-US")
        #expect(transcriptRecord.modelIdentifier == appleIdentity.modelIdentifier)
        #expect(document.modelIdentifier == appleIdentity.modelIdentifier)
        #expect(idleTimerChanges == [true, false])

        let tinySummary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "c", count: 64)
        )
        let tinyIdentity = EpisodeTranscriptionModelIdentity(summary: tinySummary)
        let state = store.jobState(
            for: episode.episodeID,
            downloadRecord: record,
            modelState: .installed(tinySummary),
            modelIdentity: tinyIdentity,
            requiresInstalledWhisperModel: true
        )
        if case .ready = state {
        } else {
            Issue.record("Expected ready for a different requested transcription identity, got \(state)")
        }
    }

    @Test("Interrupted Apple run notifies once and restores the idle timer")
    func interruptedAppleRunNotifiesAndRestoresIdleTimer() async throws {
        let harness = try makeAppleRunHarness(
            episodeID: "apple-interrupted",
            stream: { _ in neverFinishingStream() }
        )
        var interruptionEvents: [String] = []
        var idleTimerChanges: [Bool] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        harness.store.setIdleTimerDisabled = { idleTimerChanges.append($0) }

        harness.store.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            modelContext: harness.context
        )
        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .running
        })

        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(harness.store.record(for: harness.episode.episodeID)?.state == .interrupted)
        #expect(interruptionEvents == ["\(harness.episode.episodeID):false"])
        #expect(idleTimerChanges == [true, false])
    }

    @Test("Cancelling an Apple run does not notify and restores the idle timer")
    func cancelledAppleRunDoesNotNotify() async throws {
        let harness = try makeAppleRunHarness(
            episodeID: "apple-cancelled",
            stream: { _ in neverFinishingStream() }
        )
        var interruptionEvents: [String] = []
        var idleTimerChanges: [Bool] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        harness.store.setIdleTimerDisabled = { idleTimerChanges.append($0) }

        harness.store.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            modelContext: harness.context
        )
        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .running
        })

        harness.store.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )

        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(harness.store.record(for: harness.episode.episodeID)?.state == .cancelled)
        #expect(interruptionEvents.isEmpty)
        #expect(idleTimerChanges == [true, false])
    }

    @Test("Failed Apple run does not notify and restores the idle timer")
    func failedAppleRunDoesNotNotify() async throws {
        let harness = try makeAppleRunHarness(
            episodeID: "apple-failed",
            stream: { _ in failingStream(message: "Apple failure") }
        )
        var interruptionEvents: [String] = []
        var idleTimerChanges: [Bool] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        harness.store.setIdleTimerDisabled = { idleTimerChanges.append($0) }

        harness.store.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            modelContext: harness.context
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .failed
                && !harness.store.hasActiveJob
        })
        #expect(interruptionEvents.isEmpty)
        #expect(idleTimerChanges == [true, false])
    }

    @Test("Clamps tiny transcript segment overlaps")
    func clampsTinyTranscriptSegmentOverlaps() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "overlap audio")
        let fakeTranscriber = FakeEpisodeTranscriber(emittedSegments: [
            OpenCastTranscriptSegment(
                id: 10,
                start: 8755.3935546875,
                end: 8760.3935546875,
                text: "Only that the goal is to tamper with numerical results.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 11,
                start: 8760.3916015625,
                end: 8767.3916015625,
                text: "not unauthorized access, not malware propagation, or other common malware objectives.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ])
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-overlap")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.segments.map(\.id) == [0, 1])
        #expect(document.segments[0].end == 8760.3935546875)
        #expect(document.segments[1].start == 8760.3935546875)
        #expect(document.segments[1].end == 8767.3916015625)
    }

    @Test("Drops blank transcript segments before persistence")
    func dropsBlankTranscriptSegmentsBeforePersistence() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "blank segment audio")
        let fakeTranscriber = FakeEpisodeTranscriber(emittedSegments: [
            OpenCastTranscriptSegment(
                id: 20,
                start: 0,
                end: 1,
                text: "   ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 21,
                start: 1,
                end: 4,
                text: "  usable transcript text  ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 22,
                start: 4,
                end: 5,
                text: "\n\t",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ])
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-blank-segments")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.segments.map(\.id) == [0])
        #expect(document.segments.map(\.text) == ["usable transcript text"])
        #expect(document.text == "usable transcript text")
    }

    @Test("Resume starts from interrupted checkpoint")
    func resumeStartsFromInterruptedCheckpoint() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "resume audio")
        let summary = modelSummary()
        let sourceSHA = try sha256(audioURL)
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: "transcript-resume", fingerprint: fingerprint)
        let baseSegments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 30,
                text: "already done",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        let document = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "transcript-resume",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [
                EpisodeTranscriptCheckpoint(id: 1, completedDuration: 30, segmentCount: 1, createdAt: .now)
            ],
            segments: baseSegments,
            text: "already done",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: "transcript-resume",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            state: .interrupted,
            audioDuration: 60,
            completedDuration: 30,
            checkpointCount: 1,
            transcriptRelativePath: relativePath
        ))
        let fakeTranscriber = FakeEpisodeTranscriber(resumedSegmentStart: 30)
        let store = EpisodeTranscriptionStore(transcriber: fakeTranscriber, fileStore: fileStore)
        store.load(modelContext: context)
        let episode = makeEpisode(episodeID: "transcript-resume")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(fakeTranscriber.lastRequest?.resumeStart == 30)
        let resumedDocument = try #require(store.document(for: episode.episodeID))
        #expect(resumedDocument.segments.map(\.start) == [0, 30, 32])
    }

    @Test("Resumed checkpoint cannot lower completed duration")
    func resumedCheckpointCannotLowerCompletedDuration() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "resume regression audio")
        let summary = modelSummary()
        let sourceSHA = try sha256(audioURL)
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: "transcript-resume-regression", fingerprint: fingerprint)
        let document = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "transcript-resume-regression",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume-regression.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [
                EpisodeTranscriptCheckpoint(id: 1, completedDuration: 30, segmentCount: 0, createdAt: .now)
            ],
            segments: [],
            text: "",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: "transcript-resume-regression",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume-regression.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            state: .interrupted,
            audioDuration: 60,
            completedDuration: 30,
            checkpointCount: 1,
            transcriptRelativePath: relativePath
        ))
        let fakeTranscriber = RegressingCheckpointEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(transcriber: fakeTranscriber, fileStore: fileStore)
        store.load(modelContext: context)
        let episode = makeEpisode(episodeID: "transcript-resume-regression")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.checkpointCount == 2
        })
        #expect(fakeTranscriber.lastRequest?.resumeStart == 30)
        let resumedRecord = try #require(store.record(for: episode.episodeID))
        #expect(resumedRecord.completedDuration == 30)
        let resumedDocument = try #require(store.document(for: episode.episodeID))
        #expect(resumedDocument.checkpoints.last?.completedDuration == 30)
    }

    @Test("Checkpoint rewrites are throttled to every fifth checkpoint plus final")
    func checkpointRewritesAreThrottledToEveryFifthCheckpointPlusFinal() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "throttle cadence audio")
        let transcriber = ManualEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: "throttle-cadence",
            duration: 100,
            audioURL: "https://example.com/throttle-cadence.mp3",
            guid: "throttle-cadence"
        )
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil { transcriber.isStreaming })

        transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 1, audioDuration: 100)))
        #expect(await waitUntil { store.record(for: episode.episodeID)?.completedDuration == 10 })

        // Skipped checkpoints must leave the durable stamps untouched; a
        // broken throttle would advance completedDuration within this window.
        transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 2, audioDuration: 100)))
        transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 3, audioDuration: 100)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.record(for: episode.episodeID)?.completedDuration == 10)

        for index in 4...6 {
            transcriber.emit(.checkpoint(cumulativeCheckpoint(index: index, audioDuration: 100)))
        }
        #expect(await waitUntil { store.record(for: episode.episodeID)?.completedDuration == 60 })
        let midRecord = try #require(store.record(for: episode.episodeID))
        // Within one run each rewrite replaces the single in-run checkpoint
        // entry, so the count stays 1 while the duration advances 10 → 60.
        #expect(midRecord.checkpointCount == 1)
        let midDocument = try #require(store.document(for: episode.episodeID))
        #expect(midDocument.checkpoints.count == 1)
        #expect(midDocument.checkpoints.last?.completedDuration == 60)
        #expect(midDocument.segments.count == 6)

        transcriber.emit(.finished(manualResult(segmentCount: 6)))
        transcriber.finish()
        #expect(await waitUntil { store.record(for: episode.episodeID)?.state == .completed })
        let finalDocument = try #require(store.document(for: episode.episodeID))
        #expect(finalDocument.segments.count == 6)
    }

    @Test("Deleting a transcript mid-run abandons the pending-checkpoint flush")
    func deleteMidRunAbandonsPendingCheckpointFlush() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "delete flush audio")
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriber = ManualEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(transcriber: transcriber, fileStore: fileStore)
        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: "delete-mid-run-flush",
            duration: 100,
            audioURL: "https://example.com/delete-mid-run-flush.mp3",
            guid: "delete-mid-run-flush"
        )
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil { transcriber.isStreaming })
        transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 1, audioDuration: 100)))
        #expect(await waitUntil { store.record(for: episode.episodeID)?.completedDuration == 10 })
        // Checkpoint 2 is throttled into pendingCheckpoint, so the dying
        // run's terminal flush has a document rewrite to abandon.
        transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 2, audioDuration: 100)))
        try await Task.sleep(for: .milliseconds(300))

        store.deleteTranscript(episodeID: episode.episodeID, modelContext: context)
        #expect(await waitUntil { !store.hasActiveJob })

        // The flush must not mutate the deleted record or rewrite the
        // transcript document into the swept per-episode directory.
        #expect(store.record(for: episode.episodeID) == nil)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
        let episodeDirectory = temporaryDirectory
            .appending(path: EpisodeTranscriptFileStore.directoryName, directoryHint: .isDirectory)
            .appending(path: fileStore.safeStem(episode.episodeID), directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: episodeDirectory.path) == false)
    }

    @Test(
        "Kill at every checkpoint index leaves stamps and document consistent and resumes from the last written checkpoint",
        arguments: 1...7
    )
    func killAtCheckpointIndexResumesFromLastWrittenCheckpoint(killIndex: Int) async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "kill matrix audio \(killIndex)")
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriber = ManualEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(transcriber: transcriber, fileStore: fileStore)
        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: "kill-matrix-\(killIndex)",
            duration: 100,
            audioURL: "https://example.com/kill-matrix-\(killIndex).mp3",
            guid: "kill-matrix-\(killIndex)"
        )
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil { transcriber.isStreaming })
        for index in 1...killIndex {
            transcriber.emit(.checkpoint(cumulativeCheckpoint(index: index, audioDuration: 100)))
        }
        // Writes land at checkpoints 1 and 6; skipped checkpoints leave the
        // stamps untouched, so the durable floor is deterministic per index.
        // (Each in-run rewrite replaces the single run checkpoint entry, so
        // checkpointCount stays 1 while completedDuration advances.)
        let expectedWrittenIndex = killIndex >= 6 ? 6 : 1
        let expectedDuration = TimeInterval(expectedWrittenIndex) * 10
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.checkpointCount == 1
                && store.record(for: episode.episodeID)?.completedDuration == expectedDuration
        })

        // Simulated kill: the abandoned run never gets a terminal path; a
        // fresh context and store model the relaunch reading committed state.
        let relaunchContext = ModelContext(container)
        let resumeTranscriber = ManualEpisodeTranscriber()
        let relaunchStore = EpisodeTranscriptionStore(transcriber: resumeTranscriber, fileStore: fileStore)
        relaunchStore.load(modelContext: relaunchContext)

        let relaunchRecord = try #require(relaunchStore.record(for: episode.episodeID))
        #expect(relaunchRecord.state == .interrupted)
        #expect(relaunchRecord.checkpointCount == 1)
        #expect(relaunchRecord.completedDuration == expectedDuration)
        let killedDocument = try #require(relaunchStore.document(for: episode.episodeID))
        #expect(killedDocument.checkpoints.count == relaunchRecord.checkpointCount)
        #expect(killedDocument.checkpoints.last?.completedDuration == relaunchRecord.completedDuration)
        #expect(killedDocument.segments.count == expectedWrittenIndex)

        let relaunchDownload = try #require(
            try relaunchContext.fetch(FetchDescriptor<EpisodeDownloadRecord>()).first
        )
        relaunchStore.startTranscription(
            episode,
            downloadRecord: relaunchDownload,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: relaunchContext
        )
        #expect(await waitUntil { resumeTranscriber.isStreaming })
        #expect(resumeTranscriber.lastRequest?.resumeStart == expectedDuration)
        resumeTranscriber.finish()
    }

    @Test("Resume after a throttled kill matches an uninterrupted run's final output")
    func resumeAfterThrottledKillMatchesUninterruptedRun() async throws {
        // Throttled lane: four checkpoints (write at 1; 2-4 skipped), killed,
        // relaunched, resumed from 10s.
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "equivalence audio")
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriber = ManualEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(transcriber: transcriber, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "throttle-equivalence")
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil { transcriber.isStreaming })
        for index in 1...4 {
            transcriber.emit(.checkpoint(cumulativeCheckpoint(index: index, audioDuration: 60)))
        }
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.checkpointCount == 1
                && store.record(for: episode.episodeID)?.completedDuration == 10
        })

        let relaunchContext = ModelContext(container)
        let resumeTranscriber = ManualEpisodeTranscriber()
        let relaunchStore = EpisodeTranscriptionStore(transcriber: resumeTranscriber, fileStore: fileStore)
        relaunchStore.load(modelContext: relaunchContext)
        let relaunchDownload = try #require(
            try relaunchContext.fetch(FetchDescriptor<EpisodeDownloadRecord>()).first
        )
        relaunchStore.startTranscription(
            episode,
            downloadRecord: relaunchDownload,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: relaunchContext
        )
        #expect(await waitUntil { resumeTranscriber.isStreaming })
        #expect(resumeTranscriber.lastRequest?.resumeStart == 10)
        resumeTranscriber.emit(.finished(manualResult(segmentRange: 1..<6)))
        resumeTranscriber.finish()
        #expect(await waitUntil { relaunchStore.record(for: episode.episodeID)?.state == .completed })
        let resumedDocument = try #require(relaunchStore.document(for: episode.episodeID))

        // Uninterrupted lane over its own container and directory.
        let plainContainer = try OpenCastModelContainerFactory.make(inMemory: true)
        let plainContext = ModelContext(plainContainer)
        let plainDirectory = try makeTemporaryDirectory()
        let plainAudioURL = try writeAudioPlaceholder(in: plainDirectory, contents: "equivalence audio")
        let plainTranscriber = ManualEpisodeTranscriber()
        let plainStore = EpisodeTranscriptionStore(
            transcriber: plainTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: plainDirectory)
        )
        let plainRecord = completedDownloadRecord(episode: episode)
        plainContext.insert(plainRecord)
        plainStore.startTranscription(
            episode,
            downloadRecord: plainRecord,
            localFileURL: plainAudioURL,
            modelSummary: modelSummary(),
            modelContext: plainContext
        )
        #expect(await waitUntil { plainTranscriber.isStreaming })
        plainTranscriber.emit(.finished(manualResult(segmentRange: 0..<6)))
        plainTranscriber.finish()
        #expect(await waitUntil { plainStore.record(for: episode.episodeID)?.state == .completed })
        let plainDocument = try #require(plainStore.document(for: episode.episodeID))

        #expect(resumedDocument.text == plainDocument.text)
        #expect(resumedDocument.segments.map(\.start) == plainDocument.segments.map(\.start))
        #expect(resumedDocument.segments.map(\.end) == plainDocument.segments.map(\.end))
        #expect(resumedDocument.segments.map(\.text) == plainDocument.segments.map(\.text))
    }

    private func tenSecondSegment(index: Int) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: index,
            start: TimeInterval(index) * 10,
            end: TimeInterval(index + 1) * 10,
            text: "segment \(index)",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
    }

    private func cumulativeCheckpoint(
        index: Int,
        audioDuration: TimeInterval
    ) -> OpenCastLongFormTranscriptionCheckpoint {
        let segments = (0..<index).map(tenSecondSegment)
        return OpenCastLongFormTranscriptionCheckpoint(
            index: index,
            audioDuration: audioDuration,
            completedDuration: TimeInterval(index) * 10,
            segments: segments,
            text: segments.map(\.text).joined(separator: " ")
        )
    }

    private func manualResult(segmentCount: Int) -> OpenCastTranscriptionResult {
        manualResult(segmentRange: 0..<segmentCount)
    }

    private func manualResult(segmentRange: Range<Int>) -> OpenCastTranscriptionResult {
        let segments = segmentRange.map(tenSecondSegment)
        return OpenCastTranscriptionResult(
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            languageCode: "en",
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            timings: OpenCastTranscriptionTimings(
                audioDuration: 60,
                modelLoading: 1,
                audioLoading: 1,
                transcription: 2,
                fullPipeline: 4,
                realTimeFactor: 0.03,
                decodingFallbackCount: 1,
                decodingFallback: 0.5,
                decodingWindowCount: 2
            )
        )
    }

    @Test("Deleting source download preserves completed transcript")
    func deletingSourceDownloadPreservesCompletedTranscript() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "preserve-completed")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })

        store.handleDownloadDeletion(record, localFileURL: audioURL, modelContext: context)

        #expect(store.record(for: episode.episodeID)?.state == .completed)
        #expect(store.document(for: episode.episodeID) != nil)
    }

    @Test("Active transcription without progress remains running")
    func activeTranscriptionWithoutProgressRemainsRunning() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "loading audio")
        let fakeTranscriber = BlockingThenCompletingEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "loading-before-progress")
        let record = completedDownloadRecord(episode: episode)
        let summary = modelSummary()

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )

        #expect(await waitUntil { fakeTranscriber.requestCount == 1 })
        let state = store.jobState(
            for: episode.episodeID,
            downloadRecord: record,
            modelState: .installed(summary)
        )
        let isRunning: Bool
        if case .running = state {
            isRunning = true
        } else {
            isRunning = false
        }
        #expect(isRunning)
    }

    @Test("Immediate retry after cancel starts a new run")
    func immediateRetryAfterCancelStartsNewRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "retry audio")
        let fakeTranscriber = BlockingThenCompletingEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "retry-after-cancel")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil { fakeTranscriber.requestCount == 1 })

        store.cancelTranscription(episodeID: episode.episodeID, modelContext: context)
        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil { fakeTranscriber.requestCount == 2 })
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
    }

    @Test("Unload runtime waits for active transcription teardown")
    func unloadRuntimeWaitsForActiveTranscriptionTeardown() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "unload audio")
        let fakeTranscriber = SuspendingUnloadEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "unload-runtime")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil { fakeTranscriber.requestCount == 1 })
        let unloadTask = Task { @MainActor in
            await store.unloadRuntime()
        }
        #expect(await waitUntil { fakeTranscriber.isFirstUnloadSuspended })
        #expect(store.hasActiveJob)

        fakeTranscriber.releaseFirstUnload()
        await unloadTask.value

        #expect(!store.hasActiveJob)
        #expect(fakeTranscriber.unloadCallCount >= 1)
    }

    @Test("Nuke waits for active transcription teardown before clearing transcripts")
    func nukeWaitsForActiveTranscriptionTeardownBeforeClearingTranscripts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "nuke transcript audio")
        let fakeTranscriber = SuspendingUnloadEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "nuke-waits")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil { store.record(for: episode.episodeID) != nil })
        let nukeTask = Task { @MainActor in
            try await store.nukeAllTranscripts(modelContext: context)
        }
        #expect(await waitUntil { fakeTranscriber.isFirstUnloadSuspended })
        #expect(store.record(for: episode.episodeID) != nil)

        fakeTranscriber.releaseFirstUnload()
        try await nukeTask.value

        #expect(!store.hasActiveJob)
        #expect(store.records.isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
    }

    @Test("Unknown model identifier fails before service fallback")
    func unknownModelIdentifierFailsBeforeServiceFallback() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "unknown model audio")
        let request = EpisodeTranscriptionRunRequest(
            audioFileURL: audioURL,
            languageCode: "en",
            resumeStart: nil,
            sourceAudioURL: "https://example.com/unknown.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: String(repeating: "a", count: 64),
            modelIdentifier: "unknown-model",
            modelVersion: "v1",
            modelTreeSHA256: String(repeating: "b", count: 64)
        )

        let stream = OpenCastEpisodeTranscriber().transcribe(request)

        do {
            for try await _ in stream {
            }
            Issue.record("Expected unsupported model identifier")
        } catch let error as OpenCastTranscriptionError {
            #expect(error == .unsupportedModelIdentifier("unknown-model"))
        } catch {
            Issue.record("Expected unsupportedModelIdentifier, got \(error)")
        }
    }

    @Test("Background CoreML failure retries once on CPU-only and completes")
    func backgroundCoreMLFailureRetriesCPUOnlyAndCompletes() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "cpu fallback audio")
        let transcriber = CoreMLFailingThenCompletingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        let episode = makeEpisode(episodeID: "background-cpu-retry")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe, .cpuOnly])
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
    }

    @Test("CPU fallback resumes from the persisted checkpoint")
    func cpuFallbackResumesFromPersistedCheckpoint() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "checkpoint cpu fallback audio")
        let transcriber = CheckpointThenCoreMLFailingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        let episode = makeEpisode(episodeID: "background-cpu-retry-checkpoint")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe, .cpuOnly])
        #expect(transcriber.requests.last?.resumeStart == 12)
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.segments.map(\.start) == [0, 12, 14])
    }

    @Test("CPU-only environmental failure becomes resumable interruption")
    func cpuOnlyEnvironmentalFailureBecomesInterruption() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "cpu fallback failure audio")
        let transcriber = AlwaysCoreMLFailingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        let episode = makeEpisode(episodeID: "background-cpu-interrupt")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .interrupted
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe, .cpuOnly])
        #expect(transcriptRecord.errorMessage == EpisodeTranscriptionStore.environmentalInterruptMessage)
        #expect(store.hasEnvironmentalInterruptionPending(for: episode.episodeID))
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
    }

    @Test("Foreground CoreML failure remains terminal")
    func foregroundCoreMLFailureRemainsTerminal() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "foreground failure audio")
        let transcriber = AlwaysCoreMLFailingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { .foreground }
        )
        let episode = makeEpisode(episodeID: "foreground-coreml-failed")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .failed
        })
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe])
        #expect(store.record(for: episode.episodeID)?.errorMessage == coreMLError().localizedDescription)
    }

    @Test("Partial-preserving cancellation wins over a late CoreML error")
    func partialPreservingCancellationWinsOverLateCoreMLError() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "expiration race audio")
        let transcriber = CheckpointThenManualFailureTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { .foreground }
        )
        var interruptionEvents: [String] = []
        store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        let episode = makeEpisode(episodeID: "expiration-coreml-race")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.checkpointCount == 1
        })
        store.interruptActiveJob(modelContext: context)
        transcriber.failWithCoreML()

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .interrupted
                && !store.hasActiveJob
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        #expect(transcriptRecord.completedDuration == 12)
        #expect(transcriptRecord.errorMessage == nil)
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
        #expect(interruptionEvents.isEmpty)
    }

    @Test("Persists word timings with current schema version through checkpoint and final")
    func persistsWordTimingsWithCurrentSchemaVersion() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "worded audio")
        let wordedSegments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 2,
                text: "hello there",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01,
                words: [
                    OpenCastTranscriptWord(start: 0, end: 1, text: "hello"),
                    OpenCastTranscriptWord(start: 1.25, end: 2, text: "there")
                ]
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 2,
                end: 4,
                text: "line level",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(emittedSegments: wordedSegments),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-words")
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.schemaVersion == EpisodeTranscriptDocument.currentSchemaVersion)
        #expect(document.segments.first?.words == [
            OpenCastTranscriptWord(start: 0, end: 1, text: "hello"),
            OpenCastTranscriptWord(start: 1.25, end: 2, text: "there")
        ])
        #expect(document.segments.last?.words == nil)
    }

    @Test("Reads v1 documents as segments without words")
    func readsV1DocumentsAsSegmentsWithoutWords() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let relativePath = fileStore.relativePath(episodeID: "legacy-episode", fingerprint: "legacy")
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let v1JSON = Data("""
        {
          "schemaVersion": 1,
          "episodeID": "legacy-episode",
          "podcastID": "https://example.com/feed.xml",
          "sourceAudioURL": "https://example.com/legacy.mp3",
          "sourceFileByteCount": 10,
          "sourceFileSHA256": "abc",
          "modelIdentifier": "openai_whisper-tiny.en",
          "modelVersion": "1",
          "modelTreeSHA256": "def",
          "languageCode": "en",
          "audioDuration": 60,
          "checkpoints": [],
          "segments": [
            {"id": 0, "start": 0, "end": 2, "text": "legacy line", "avgLogProbability": -0.1, "noSpeechProbability": 0.01}
          ],
          "text": "legacy line",
          "timings": {
            "modelLoading": 0,
            "audioLoading": 0,
            "transcription": 0,
            "fullPipeline": 0,
            "realTimeFactor": 0,
            "decodingFallbackCount": 0,
            "decodingFallback": 0,
            "decodingWindowCount": 0
          },
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.utf8)
        try v1JSON.write(to: fileURL, options: .atomic)

        let document = try fileStore.read(relativePath: relativePath)
        #expect(document.schemaVersion == 1)
        #expect(document.segments.count == 1)
        #expect(document.segments.first?.words == nil)
    }

    @Test("Reads v2 documents and infers engine provenance from the model identifier")
    func readsV2DocumentsAndInfersEngineProvenance() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let relativePath = fileStore.relativePath(episodeID: "v2-episode", fingerprint: "v2")
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        func v2JSON(modelIdentifier: String) -> Data {
            Data("""
            {
              "schemaVersion": 2,
              "episodeID": "v2-episode",
              "podcastID": "https://example.com/feed.xml",
              "sourceAudioURL": "https://example.com/v2.mp3",
              "sourceFileByteCount": 10,
              "sourceFileSHA256": "abc",
              "modelIdentifier": "\(modelIdentifier)",
              "modelVersion": "1",
              "modelTreeSHA256": "def",
              "languageCode": "en",
              "audioDuration": 60,
              "checkpoints": [],
              "segments": [],
              "text": "",
              "timings": {
                "modelLoading": 0,
                "audioLoading": 0,
                "transcription": 0,
                "fullPipeline": 0,
                "realTimeFactor": 0,
                "decodingFallbackCount": 0,
                "decodingFallback": 0,
                "decodingWindowCount": 0
              },
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            }
            """.utf8)
        }

        try v2JSON(modelIdentifier: "openai_whisper-tiny.en").write(to: fileURL, options: .atomic)
        let whisperDocument = try fileStore.read(relativePath: relativePath)
        #expect(whisperDocument.schemaVersion == 2)
        #expect(whisperDocument.transcriptionEngine == nil)
        #expect(whisperDocument.modelIdentifier == "openai_whisper-tiny.en")
        #expect(whisperDocument.remoteSourceMatchMode == nil)

        try v2JSON(modelIdentifier: "apple-speech-transcriber.en-US").write(to: fileURL, options: .atomic)
        let appleDocument = try fileStore.read(relativePath: relativePath)
        #expect(appleDocument.transcriptionEngine == nil)
        #expect(appleDocument.modelIdentifier == "apple-speech-transcriber.en-US")
    }

    @Test("Round-trips schema 3 remote provenance fields")
    func roundTripsSchema3RemoteProvenance() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let relativePath = fileStore.relativePath(episodeID: "remote-episode", fingerprint: "remote")
        var document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: "remote-episode",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/remote.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "abc",
            modelIdentifier: "remote-whisper-large-v3-turbo",
            modelVersion: "serving-contract-1",
            modelTreeSHA256: "",
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: [],
            text: "",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        document.transcriptionEngine = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        document.providerModelIdentifier = "@cf/openai/whisper-large-v3-turbo"
        document.remoteServingContractVersion = "1"
        document.remotePipelineVersion = "pass0"
        document.remoteRequestSettingsSHA256 = "aa"
        document.remoteChunkManifestSHA256 = "bb"
        document.normalizedTranscriptSHA256 = "cc"
        document.remoteJobProvenanceToken = "job-token"
        document.remoteSourceMatchMode = EpisodeRemoteTranscriptSourceMatchMode.serverDeviceHashMatch.rawValue
        try fileStore.write(document, relativePath: relativePath)

        let decoded = try fileStore.read(relativePath: relativePath)
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.transcriptionEngine == EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue)
        #expect(decoded.providerModelIdentifier == "@cf/openai/whisper-large-v3-turbo")
        #expect(decoded.providerModelRevision == nil)
        #expect(decoded.remoteChunkManifestSHA256 == "bb")
        #expect(decoded.normalizedTranscriptSHA256 == "cc")
        #expect(decoded.remoteSourceMatchMode == EpisodeRemoteTranscriptSourceMatchMode.serverDeviceHashMatch.rawValue)
        #expect(decoded.modelTreeSHA256.isEmpty)
    }

    @Test("Remote fingerprint is domain-separated and contract-sensitive")
    func remoteFingerprintIsDomainSeparatedAndContractSensitive() throws {
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let localFingerprint = fileStore.fingerprint(
            sourceFileSHA256: "abc",
            modelIdentifier: "m",
            modelVersion: "v",
            modelTreeSHA256: "t"
        )
        let remoteFingerprint = fileStore.remoteFingerprint(
            sourceFileSHA256: "abc",
            provider: "cloudflare-workers-ai",
            providerModelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            servingContractVersion: "1",
            pipelineVersion: "pass0"
        )
        let bumpedContractFingerprint = fileStore.remoteFingerprint(
            sourceFileSHA256: "abc",
            provider: "cloudflare-workers-ai",
            providerModelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            servingContractVersion: "2",
            pipelineVersion: "pass0"
        )
        #expect(localFingerprint != remoteFingerprint)
        #expect(remoteFingerprint != bumpedContractFingerprint)
        #expect(remoteFingerprint == fileStore.remoteFingerprint(
            sourceFileSHA256: "abc",
            provider: "cloudflare-workers-ai",
            providerModelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            servingContractVersion: "1",
            pipelineVersion: "pass0"
        ))
    }

    @Test("Record engine provenance distinguishes local, Apple Speech, and remote")
    func recordEngineProvenance() {
        let record = EpisodeTranscriptRecord(
            episodeID: "e",
            podcastID: "p",
            sourceAudioURL: "https://example.com/a.mp3"
        )
        record.modelIdentifier = "openai_whisper-tiny.en"
        #expect(record.engineProvenance == .localWhisper)
        #expect(!record.isAppleSpeechTranscript)

        record.modelIdentifier = "apple-speech-transcriber.en-US"
        #expect(record.engineProvenance == .appleSpeech)
        #expect(record.isAppleSpeechTranscript)

        record.transcriptionEngineRawValue = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        #expect(record.engineProvenance == .remoteWhisper)
        #expect(!record.isAppleSpeechTranscript)
    }

    @Test("Interrupted improve run restores the prior completed transcript")
    func interruptedImproveRunRestoresPriorCompletedTranscript() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-interrupt",
            secondAttemptStream: { _ in neverFinishingStream() }
        )
        var interruptionEvents: [String] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }

        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let restored = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(restored.modelIdentifier == harness.priorModelIdentifier)
        #expect(restored.transcriptRelativePath == harness.priorRelativePath)
        #expect(restored.errorMessage == nil)
        let document = try #require(harness.store.document(for: harness.episode.episodeID))
        #expect(document.modelIdentifier == harness.priorModelIdentifier)
        #expect(harness.store.lastErrorMessage(for: harness.episode.episodeID) == nil)
        #expect(interruptionEvents == ["\(harness.episode.episodeID):true"])
    }

    @Test("Cancelled improve run restores the prior completed transcript")
    func cancelledImproveRunRestoresPriorCompletedTranscript() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-cancel",
            secondAttemptStream: { _ in neverFinishingStream() }
        )

        harness.store.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let restored = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(restored.modelIdentifier == harness.priorModelIdentifier)
        #expect(restored.transcriptRelativePath == harness.priorRelativePath)
        #expect(harness.store.document(for: harness.episode.episodeID) != nil)
    }

    @Test("Failed improve run restores the prior transcript and surfaces the failure")
    func failedImproveRunRestoresPriorTranscriptAndSurfacesFailure() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-fail",
            secondAttemptStream: { _ in failingStream(message: "Deterministic improve failure") }
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let restored = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(restored.modelIdentifier == harness.priorModelIdentifier)
        #expect(restored.transcriptRelativePath == harness.priorRelativePath)
        #expect(harness.store.document(for: harness.episode.episodeID) != nil)
        #expect(harness.store.lastErrorMessage(for: harness.episode.episodeID) == "Deterministic improve failure")
    }

    @Test("Completed improve replaces the record and deletes the superseded document")
    func completedImproveReplacesRecordAndDeletesSupersededDocument() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-complete",
            secondAttemptStream: { request in FakeEpisodeTranscriber().transcribe(request) }
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.modelIdentifier == appleImproveIdentity().modelIdentifier
                && harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let improved = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(improved.languageCode == "en-US")
        let document = try #require(harness.store.document(for: harness.episode.episodeID))
        #expect(document.modelIdentifier == appleImproveIdentity().modelIdentifier)
        #expect(!harness.fileStore.documentExists(relativePath: harness.priorRelativePath))
    }

    @Test("A trusted source match reads only a transcript of the trusted bytes as completed")
    func trustedSourceMatchReadsOnlyMatchingTranscriptAsCompleted() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let episode = makeEpisode(episodeID: "source-match")
        let document = try insertCompletedTranscript(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            text: "transcript of earlier bytes",
            fileStore: fileStore,
            modelContext: context
        )
        let store = EpisodeTranscriptionStore(transcriber: FakeEpisodeTranscriber(), fileStore: fileStore)
        store.load(modelContext: context)
        let record = try #require(store.record(for: episode.episodeID))
        let downloadRecord = completedDownloadRecord(episode: episode)
        let summary = modelSummary()
        let recordIdentity = EpisodeTranscriptionModelIdentity(
            modelIdentifier: record.modelIdentifier,
            version: record.modelVersion,
            treeSHA256: record.modelTreeSHA256
        )
        func state(
            _ sourceMatch: EpisodeTranscriptionSourceMatch,
            modelIdentity: EpisodeTranscriptionModelIdentity? = nil
        ) -> EpisodeTranscriptionJobState {
            store.jobState(
                for: episode.episodeID,
                downloadRecord: downloadRecord,
                modelState: .installed(summary),
                modelIdentity: modelIdentity,
                sourceMatch: sourceMatch
            )
        }

        // Display surfaces keep seeing the transcript, whatever audio it describes.
        #expect(state(.any) == .completed(record))
        #expect(state(.trusted(sha256: document.sourceFileSHA256)) == .completed(record))
        // Other bytes, or no trusted download, leave the episode ready to
        // transcribe again, with or without a model identity to match.
        #expect(state(.trusted(sha256: "other-bytes")) == .ready)
        #expect(state(.trusted(sha256: nil)) == .ready)
        #expect(state(.trusted(sha256: document.sourceFileSHA256), modelIdentity: recordIdentity) == .completed(record))
        #expect(state(.trusted(sha256: "other-bytes"), modelIdentity: recordIdentity) == .ready)

        // A transcript with no recorded hash proves no bytes.
        record.sourceFileSHA256 = ""
        #expect(state(.trusted(sha256: document.sourceFileSHA256)) == .ready)
        #expect(state(.trusted(sha256: "")) == .ready)
        #expect(state(.any) == .completed(record))

        // Only a completed transcript is held to the source; an interrupted
        // one still reads interrupted, so its own resume path stays as it is.
        record.sourceFileSHA256 = document.sourceFileSHA256
        record.state = .interrupted
        #expect(state(.trusted(sha256: "other-bytes")) == .interrupted(record))
    }

    @Test("An interrupted Whisper replacement restores the prior transcript, keeps its partial and resumes from it")
    func interruptedWhisperReplacementKeepsPartialAndResumes() async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-interrupted")
        #expect(await startReplacementAndCheckpoint(harness))
        let partialPath = try replacementPartialRelativePath(harness)

        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(harness.fileStore.documentExists(relativePath: partialPath))
        #expect(
            harness.store.interruptedReplacement(for: harness.episodeID)
                == EpisodeTranscriptionReplacementInterruption(isEnvironmental: false)
        )
        // The record reads the restored transcript; only the note knows.
        #expect(!harness.store.hasEnvironmentalInterruptionPending(for: harness.episodeID))
        #expect(!harness.store.hasResumableWhisperCheckpoint(for: harness.episodeID))

        try await expectReplacementResumesAndCompletes(harness)
    }

    @Test("An environmental failure of a Whisper replacement restores the prior transcript, keeps its partial and resumes from it")
    func environmentalWhisperReplacementFailureKeepsPartialAndResumes() async throws {
        let harness = try makeReplacementHarness(
            episodeID: "replacement-environmental",
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        #expect(await startReplacementAndCheckpoint(harness, initialComputeProfile: .cpuOnly))
        let partialPath = try replacementPartialRelativePath(harness)

        harness.transcriber.fail(with: coreMLError())

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(harness.fileStore.documentExists(relativePath: partialPath))
        #expect(
            harness.store.interruptedReplacement(for: harness.episodeID)
                == EpisodeTranscriptionReplacementInterruption(isEnvironmental: true)
        )
        // The record-based query stays the record's: a note whose queue item
        // went away must never be resumed from the foreground.
        #expect(!harness.store.hasEnvironmentalInterruptionPending(for: harness.episodeID))
        #expect(harness.store.lastErrorMessage(for: harness.episodeID) == nil)

        try await expectReplacementResumesAndCompletes(harness)
    }

    @Test(
        "A cancelled or failed replacement restores the prior transcript and deletes its partial",
        arguments: ReplacementStop.allCases
    )
    func stoppedReplacementRestoresPriorTranscriptAndDeletesPartial(stop: ReplacementStop) async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-\(stop)")
        #expect(await startReplacementAndCheckpoint(harness))
        let partialPath = try replacementPartialRelativePath(harness)
        #expect(harness.fileStore.documentExists(relativePath: partialPath))

        switch stop {
        case .userCancel:
            harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        case .hardFailure:
            harness.transcriber.fail(with: replacementFailure("Deterministic replacement failure"))
        }

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(!harness.fileStore.documentExists(relativePath: partialPath))
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil)
        #expect(
            harness.store.lastErrorMessage(for: harness.episodeID)
                == (stop == .hardFailure ? "Deterministic replacement failure" : nil)
        )
        // A cancel leaves only its note to say so, read once; a failure
        // says why in its recorded error.
        #expect(harness.store.consumeCancelledReplacement(for: harness.episodeID) == (stop == .userCancel))
        #expect(!harness.store.consumeCancelledReplacement(for: harness.episodeID))
    }

    @Test("A cancel during a replacement's setup is noted as a cancel, and a start clears the note")
    func cancelDuringReplacementSetupIsNoted() async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-setup-cancelled")

        #expect(startReplacement(harness))
        // Before the run's task starts: it is cancelled through the identity
        // load and stops while the record still reads the prior transcript.
        harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(harness.transcriber.requestCount == 0)
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil)
        #expect(harness.store.consumeCancelledReplacement(for: harness.episodeID))
        #expect(!harness.store.consumeCancelledReplacement(for: harness.episodeID))

        // A start clears a note no one read.
        #expect(startReplacement(harness))
        harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(startReplacement(harness))
        #expect(!harness.store.consumeCancelledReplacement(for: harness.episodeID))
        harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
    }

    @Test("An interrupted Apple Speech replacement restores the prior transcript and deletes its partial")
    func interruptedAppleSpeechReplacementDeletesPartial() async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-apple-interrupted")
        var interruptionEvents: [String] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        #expect(await startReplacementAndCheckpoint(
            harness,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US"
        ))
        let partialPath = try replacementPartialRelativePath(harness, modelIdentity: appleImproveIdentity())
        #expect(harness.fileStore.documentExists(relativePath: partialPath))

        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(!harness.fileStore.documentExists(relativePath: partialPath))
        #expect(
            harness.store.interruptedReplacement(for: harness.episodeID)
                == EpisodeTranscriptionReplacementInterruption(isEnvironmental: false)
        )
        #expect(interruptionEvents == ["\(harness.episodeID):true"])

        harness.store.deleteTranscript(episodeID: harness.episodeID, modelContext: harness.context)
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil)
    }

    @Test(
        "A hashing or duration failure before a preserving run leaves the prior transcript completed",
        arguments: ReplacementSetupFailure.allCases,
        [PriorCompletedTranscriptPolicy.preserve, .preserveKeepingInterruptedPartial]
    )
    func setupFailureLeavesPriorTranscriptCompleted(
        failure: ReplacementSetupFailure,
        policy: PriorCompletedTranscriptPolicy
    ) async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-setup-\(failure)-\(policy)")
        let episode = failure == .duration
            ? EpisodeListItemSnapshot.fixture(
                episodeID: harness.episodeID,
                duration: nil,
                audioURL: harness.episode.audioURL,
                guid: harness.episodeID
            )
            : harness.episode

        #expect(startReplacement(harness, episode: episode, policy: policy))
        if failure == .hashing {
            // The run's task has not started yet; it finds no file to hash.
            try FileManager.default.removeItem(at: harness.audioURL)
        }

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(harness.store.lastErrorMessage(for: harness.episodeID) != nil)
        #expect(harness.transcriber.requestCount == 0)
    }

    @Test("An interruption during a replacement's setup is noted, and consuming the note clears it")
    func interruptionDuringReplacementSetupIsNoted() async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-setup-interrupted")
        let note = EpisodeTranscriptionReplacementInterruption(isEnvironmental: false)

        #expect(startReplacement(harness))
        // Before the run's task starts: it is cancelled through the identity
        // load and stops while the record still reads the prior transcript.
        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(harness.transcriber.requestCount == 0)
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == note)
        #expect(harness.store.consumeInterruptedReplacement(for: harness.episodeID) == note)
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil)
        #expect(harness.store.consumeInterruptedReplacement(for: harness.episodeID) == nil)
    }

    @Test(
        "A kept partial is not resumed for other bytes, another model, another language or another duration",
        arguments: ReplacementResumeMismatch.allCases
    )
    func keptPartialIsNotResumedForAnotherSource(mismatch: ReplacementResumeMismatch) async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-mismatch-\(mismatch)")
        #expect(await startReplacementAndCheckpoint(harness))
        harness.store.interruptActiveJob(modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
        let keptPartial = try harness.fileStore.read(relativePath: try replacementPartialRelativePath(harness))

        var episode = harness.episode
        var audioURL = harness.audioURL
        var modelIdentity = EpisodeTranscriptionModelIdentity(summary: modelSummary())
        var languageCode = "en"
        switch mismatch {
        case .otherBytes:
            // As many bytes as the kept partial describes: only its hash differs.
            audioURL = try writeAudioPlaceholder(
                in: harness.directory,
                contents: "fresh assembly \(harness.episodeID)".uppercased()
            )
        case .otherModel:
            modelIdentity = tinyModelIdentity()
        case .otherLanguage:
            languageCode = "de"
        case .otherDuration:
            episode = .fixture(
                episodeID: harness.episodeID,
                duration: 90,
                audioURL: harness.episode.audioURL,
                guid: harness.episodeID
            )
        }
        // The restart looks for a partial at its own fingerprint path. The
        // kept one is put there, so only the document's own checks refuse it.
        try harness.fileStore.write(
            keptPartial,
            relativePath: try replacementPartialRelativePath(harness, audioURL: audioURL, modelIdentity: modelIdentity)
        )
        #expect(startReplacement(
            harness,
            episode: episode,
            audioURL: audioURL,
            modelIdentity: modelIdentity,
            languageCode: languageCode
        ))

        #expect(await waitUntil { harness.transcriber.requestCount == 2 })
        #expect(harness.transcriber.lastRequest?.resumeStart == nil)
        harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
    }

    @Test(
        "Deleting the download mid-replacement leaves the prior transcript completed, also when the cancelled run then fails",
        arguments: DownloadDeletionScope.allCases, [false, true]
    )
    func downloadDeletionMidReplacementRestoresPriorTranscript(
        scope: DownloadDeletionScope,
        runFailsAfterDeletion: Bool
    ) async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-deleted-\(scope)-\(runFailsAfterDeletion)")
        #expect(await startReplacementAndCheckpoint(harness))
        let partialPath = try replacementPartialRelativePath(harness)
        #expect(harness.fileStore.documentExists(relativePath: partialPath))

        if runFailsAfterDeletion {
            // Delivered before the deletion cancels the run, so the run wakes
            // with this error, not a cancellation, and reaches the failure arm.
            harness.transcriber.fail(with: replacementFailure("Late replacement failure"))
        }
        switch scope {
        case .single:
            harness.store.handleDownloadDeletion(
                harness.downloadRecord,
                localFileURL: harness.audioURL,
                modelContext: harness.context
            )
        case .all:
            harness.store.handleAllDownloadsDeleted(modelContext: harness.context)
        }

        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(try harness.context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).map(\.state) == [.completed])
        #expect(!harness.fileStore.documentExists(relativePath: partialPath))
        #expect(harness.store.lastErrorMessage(for: harness.episodeID) == nil)
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil)
    }

    @Test(
        "A replacement's document write still in flight when its run ends early leaves no document behind",
        arguments: InFlightReplacementWrite.allCases
    )
    func inFlightWriteOfEndedReplacementLeavesNoDocument(write: InFlightReplacementWrite) async throws {
        let gate = DocumentGate()
        let harness = try makeReplacementHarness(episodeID: "replacement-in-flight-\(write)", documentWriteGate: gate)
        #expect(await startReplacementAndCheckpoint(harness))
        let partialPath = try replacementPartialRelativePath(harness)
        let priorName = documentName(harness.priorRelativePath)

        gate.arm()
        switch write {
        case .finalResultAcrossDownloadDeletion, .finalResultAcrossRestart:
            harness.transcriber.emit(.finished(manualResult(segmentCount: 6)))
        case .pendingCheckpointFlushAcrossDownloadDeletion:
            // Checkpoint 2 is throttled, so the failing run flushes it as it
            // unwinds, past any cancellation.
            harness.transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 2, audioDuration: 60)))
            harness.transcriber.fail(with: replacementFailure("Run failed with a checkpoint pending"))
        }
        #expect(await waitUntil { gate.heldRelativePath == partialPath })

        switch write {
        case .finalResultAcrossDownloadDeletion, .pendingCheckpointFlushAcrossDownloadDeletion:
            harness.store.handleDownloadDeletion(
                harness.downloadRecord,
                localFileURL: harness.audioURL,
                modelContext: harness.context
            )
            gate.release()

            #expect(await waitUntil { !harness.store.hasActiveJob })
            try expectPriorTranscriptRestored(harness)
            #expect(!harness.fileStore.documentExists(relativePath: partialPath))
            #expect(try episodeDocumentNames(harness) == [priorName])
        case .finalResultAcrossRestart:
            harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
            #expect(startReplacement(harness))
            #expect(await waitUntil { harness.transcriber.requestCount == 2 })
            harness.transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 1, audioDuration: 60)))
            #expect(await waitUntil {
                harness.store.record(for: harness.episodeID)?.state == .running
                    && harness.store.record(for: harness.episodeID)?.completedDuration == 10
            })
            gate.release()

            // The ended run unloads once its write has come back.
            #expect(await waitUntil { harness.transcriber.unloadCount == 1 })
            #expect(try harness.fileStore.read(relativePath: partialPath).segments.count == 1)
            #expect(try episodeDocumentNames(harness) == [priorName, documentName(partialPath)].sorted())
            harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
            #expect(await waitUntil { !harness.store.hasActiveJob })
        }
    }

    @Test(
        "A restart over a cancelled replacement that has not unwound restores the prior transcript first, keeping the partial only as the stop would",
        arguments: [PriorCompletedTranscriptPolicy.preserve, .preserveKeepingInterruptedPartial],
        ReplacementRestartStop.allCases
    )
    func restartBeforeCancelledReplacementUnwindsRestoresPriorFirst(
        policy: PriorCompletedTranscriptPolicy,
        stop: ReplacementRestartStop
    ) async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-restart-\(policy)-\(stop)")
        #expect(await startReplacementAndCheckpoint(harness, policy: policy))
        let partialPath = try replacementPartialRelativePath(harness)

        switch stop {
        case .userCancel:
            harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        case .interruption:
            harness.store.interruptActiveJob(modelContext: harness.context)
        }
        // The cancelled run needs the main actor to unwind, so it has not yet
        // when the restart is admitted.
        #expect(startReplacement(harness, policy: policy))
        try expectPriorTranscriptRestored(harness)
        let keepsPartial = stop == .interruption && policy == .preserveKeepingInterruptedPartial
        #expect(harness.fileStore.documentExists(relativePath: partialPath) == keepsPartial)

        #expect(await waitUntil { harness.transcriber.requestCount == 2 })
        let expectedResumeStart: TimeInterval? = keepsPartial ? 10 : nil
        #expect(harness.transcriber.lastRequest?.resumeStart == expectedResumeStart)
        // The restart holds the prior transcript in its turn.
        harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
        try expectPriorTranscriptRestored(harness)
        #expect(try harness.context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).map(\.state) == [.completed])
        #expect(!harness.fileStore.documentExists(relativePath: partialPath))
        #expect(harness.store.lastErrorMessage(for: harness.episodeID) == nil)
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil)
    }

    @Test(
        "A completed replacement deletes the partial an earlier interrupted attempt kept for other bytes or another model",
        arguments: [ReplacementResumeMismatch.otherBytes, .otherModel]
    )
    func completedReplacementDeletesPartialOfEarlierAttempt(mismatch: ReplacementResumeMismatch) async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-sweep-\(mismatch)")
        #expect(await startReplacementAndCheckpoint(harness))
        let keptPath = try replacementPartialRelativePath(harness)
        harness.store.interruptActiveJob(modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(harness.fileStore.documentExists(relativePath: keptPath))

        var audioURL = harness.audioURL
        var modelIdentity = EpisodeTranscriptionModelIdentity(summary: modelSummary())
        switch mismatch {
        case .otherBytes:
            audioURL = try writeAudioPlaceholder(in: harness.directory, contents: "another assembly")
        case .otherModel:
            modelIdentity = tinyModelIdentity()
        case .otherLanguage, .otherDuration:
            Issue.record("Same fingerprint path: the kept partial would be the one this run writes.")
        }
        let committedPath = try replacementPartialRelativePath(harness, audioURL: audioURL, modelIdentity: modelIdentity)
        #expect(startReplacement(harness, audioURL: audioURL, modelIdentity: modelIdentity))
        #expect(await waitUntil { harness.transcriber.requestCount == 2 })
        harness.transcriber.emit(.finished(manualResult(segmentCount: 6)))
        harness.transcriber.finish()

        #expect(await waitUntil {
            harness.store.record(for: harness.episodeID)?.state == .completed
                && harness.store.record(for: harness.episodeID)?.transcriptRelativePath == committedPath
                && !harness.store.hasActiveJob
        })
        #expect(!harness.fileStore.documentExists(relativePath: keptPath))
        #expect(try episodeDocumentNames(harness) == [documentName(committedPath)])
    }

    @Test("Importing a remote transcript deletes the partial an interrupted replacement kept")
    func remoteImportDeletesKeptReplacementPartial() async throws {
        let harness = try makeReplacementHarness(episodeID: "replacement-sweep-remote")
        #expect(await startReplacementAndCheckpoint(harness))
        let keptPath = try replacementPartialRelativePath(harness)
        harness.store.interruptActiveJob(modelContext: harness.context)
        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(harness.fileStore.documentExists(relativePath: keptPath))

        try await harness.store.importRemoteTranscript(try remoteTranscript(harness), modelContext: harness.context)

        let record = try #require(harness.store.record(for: harness.episodeID))
        #expect(record.state == .completed)
        #expect(record.engineProvenance == .remoteWhisper)
        let importedPath = try #require(record.transcriptRelativePath)
        #expect(!harness.fileStore.documentExists(relativePath: keptPath))
        #expect(try episodeDocumentNames(harness) == [documentName(importedPath)])
    }

    @Test(
        "A local run admitted while a remote import writes its document keeps the transcript: the import stands down and the prior document stays for the run to restore",
        arguments: RemoteImportOverlap.allCases
    )
    func remoteImportStandsDownForARunAdmittedDuringItsWrite(overlap: RemoteImportOverlap) async throws {
        let writeGate = DocumentGate()
        let readGate = DocumentGate()
        let harness = try makeReplacementHarness(
            episodeID: "remote-import-overlap-\(overlap)",
            documentWriteGate: writeGate,
            documentReadGate: readGate
        )
        let remote = try remoteTranscript(harness)
        let partialPath = try replacementPartialRelativePath(harness)

        // The import has found no local run and is writing its document.
        writeGate.arm()
        let importTask = Task {
            try await harness.store.importRemoteTranscript(remote, modelContext: harness.context)
        }
        #expect(await waitUntil { writeGate.heldRelativePath != nil })

        switch overlap {
        case .runInSetup:
            // The pass's replacement has taken the prior transcript to
            // restore and is held looking for a kept partial, before its
            // first record write.
            readGate.arm()
            #expect(startReplacement(harness))
            #expect(await waitUntil { readGate.heldRelativePath == partialPath })
        case .runTranscribing:
            // Improve's run has its first checkpoint on the running record.
            #expect(await startReplacementAndCheckpoint(harness, policy: .preserve))
        }
        writeGate.release()
        let imported = await importTask.result
        #expect(throws: RemoteTranscriptImportError.localTranscriptionActive) { try imported.get() }
        try expectEveryCompletedRecordHasItsDocument(harness)
        readGate.release()

        switch overlap {
        case .runInSetup:
            #expect(await waitUntil { harness.transcriber.requestCount == 1 })
            harness.store.cancelTranscription(episodeID: harness.episodeID, modelContext: harness.context)
            #expect(await waitUntil { !harness.store.hasActiveJob })
            try expectPriorTranscriptRestored(harness)
            #expect(try episodeDocumentNames(harness) == [documentName(harness.priorRelativePath)])
        case .runTranscribing:
            harness.transcriber.emit(.finished(manualResult(segmentCount: 6)))
            harness.transcriber.finish()
            #expect(await waitUntil { !harness.store.hasActiveJob })
            let record = try #require(harness.store.record(for: harness.episodeID))
            #expect(record.state == .completed)
            #expect(record.engineProvenance != .remoteWhisper)
            #expect(record.transcriptRelativePath == partialPath)
            #expect(try episodeDocumentNames(harness) == [documentName(partialPath)])
        }
        try expectEveryCompletedRecordHasItsDocument(harness)
    }

    /// A remote transcript of the harness's download, as a cloud pass
    /// imports it.
    private func remoteTranscript(_ harness: ReplacementHarness) throws -> EpisodeTranscriptDocument {
        var remote = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: harness.episodeID,
            podcastID: harness.episode.podcastID,
            sourceAudioURL: harness.downloadRecord.sourceAudioURL,
            sourceFileByteCount: Int64(try Data(contentsOf: harness.audioURL).count),
            sourceFileSHA256: try sha256(harness.audioURL),
            modelIdentifier: "remote-whisper-large-v3-turbo",
            modelVersion: "serving-contract-1",
            modelTreeSHA256: "",
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: manualResult(segmentCount: 6).segments,
            text: "remote transcript",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        remote.transcriptionEngine = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        remote.providerModelIdentifier = "@cf/openai/whisper-large-v3-turbo"
        remote.remoteServingContractVersion = "1"
        remote.remotePipelineVersion = "pass0"
        return remote
    }

    /// No transcript record reads completed while its document is gone.
    private func expectEveryCompletedRecordHasItsDocument(
        _ harness: ReplacementHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let completed = try harness.context.fetch(FetchDescriptor<EpisodeTranscriptRecord>())
            .filter { $0.state == .completed }
        for record in completed {
            #expect(
                harness.fileStore.documentExists(relativePath: record.transcriptRelativePath),
                "\(record.transcriptRelativePath ?? "nil") reads completed without its document",
                sourceLocation: sourceLocation
            )
        }
    }

    private static let replacementPriorText = "prior transcript"

    /// A completed transcript of earlier bytes (`insertCompletedTranscript`)
    /// and a fresh download of other bytes to replace it from; the store's
    /// transcriber is driven by the test.
    private func makeReplacementHarness(
        episodeID: String,
        failureEnvironment: @escaping @MainActor () -> EpisodeTranscriptionFailureEnvironment = { .foreground },
        documentWriteGate: DocumentGate? = nil,
        documentReadGate: DocumentGate? = nil
    ) throws -> ReplacementHarness {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(
            baseDirectory: directory,
            beforeDocumentWriteForTesting: documentWriteGate.map { gate in
                { @Sendable relativePath in await gate.hold(relativePath) }
            },
            beforeDocumentReadForTesting: documentReadGate.map { gate in
                { @Sendable relativePath in await gate.hold(relativePath) }
            }
        )
        let episode = makeEpisode(episodeID: episodeID)
        try insertCompletedTranscript(
            episodeID: episodeID,
            podcastID: episode.podcastID,
            text: Self.replacementPriorText,
            fileStore: fileStore,
            modelContext: context
        )
        let downloadRecord = completedDownloadRecord(episode: episode)
        context.insert(downloadRecord)
        try context.save()
        let transcriber = ManualEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: fileStore,
            failureEnvironment: failureEnvironment
        )
        store.load(modelContext: context)
        return ReplacementHarness(
            context: context,
            episode: episode,
            downloadRecord: downloadRecord,
            audioURL: try writeAudioPlaceholder(in: directory, contents: "fresh assembly \(episodeID)"),
            directory: directory,
            store: store,
            fileStore: fileStore,
            transcriber: transcriber,
            priorRelativePath: fileStore.relativePath(episodeID: episodeID, fingerprint: "fixture")
        )
    }

    @discardableResult
    private func startReplacement(
        _ harness: ReplacementHarness,
        episode: EpisodeListItemSnapshot? = nil,
        audioURL: URL? = nil,
        engine: EpisodeTranscriptionEngine = .whisper,
        modelIdentity: EpisodeTranscriptionModelIdentity? = nil,
        languageCode: String = "en",
        initialComputeProfile: OpenCastTranscriptionComputeProfile = .backgroundSafe,
        policy: PriorCompletedTranscriptPolicy = .preserveKeepingInterruptedPartial
    ) -> Bool {
        harness.store.startTranscription(
            episode ?? harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: audioURL ?? harness.audioURL,
            engine: engine,
            modelIdentity: modelIdentity ?? EpisodeTranscriptionModelIdentity(summary: modelSummary()),
            languageCode: languageCode,
            initialComputeProfile: initialComputeProfile,
            priorCompletedTranscript: policy,
            modelContext: harness.context
        )
    }

    /// Starts a replacement and waits until its first checkpoint (10 s of
    /// 60) is written and committed on the running record.
    private func startReplacementAndCheckpoint(
        _ harness: ReplacementHarness,
        engine: EpisodeTranscriptionEngine = .whisper,
        modelIdentity: EpisodeTranscriptionModelIdentity? = nil,
        languageCode: String = "en",
        initialComputeProfile: OpenCastTranscriptionComputeProfile = .backgroundSafe,
        policy: PriorCompletedTranscriptPolicy = .preserveKeepingInterruptedPartial
    ) async -> Bool {
        let requestCount = harness.transcriber.requestCount
        guard startReplacement(
            harness,
            engine: engine,
            modelIdentity: modelIdentity,
            languageCode: languageCode,
            initialComputeProfile: initialComputeProfile,
            policy: policy
        ),
            await waitUntil({ harness.transcriber.requestCount == requestCount + 1 })
        else {
            return false
        }
        harness.transcriber.emit(.checkpoint(cumulativeCheckpoint(index: 1, audioDuration: 60)))
        return await waitUntil {
            harness.store.record(for: harness.episodeID)?.state == .running
                && harness.store.record(for: harness.episodeID)?.completedDuration == 10
        }
    }

    /// Restarts an interrupted replacement: it resumes from the kept
    /// partial's checkpoint, completes over the new bytes and deletes the
    /// superseded prior document.
    private func expectReplacementResumesAndCompletes(
        _ harness: ReplacementHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let requestCount = harness.transcriber.requestCount
        #expect(startReplacement(harness), sourceLocation: sourceLocation)
        #expect(
            await waitUntil { harness.transcriber.requestCount == requestCount + 1 },
            sourceLocation: sourceLocation
        )
        #expect(harness.store.interruptedReplacement(for: harness.episodeID) == nil, sourceLocation: sourceLocation)
        #expect(harness.transcriber.lastRequest?.resumeStart == 10, sourceLocation: sourceLocation)

        harness.transcriber.emit(.finished(manualResult(segmentRange: 1..<6)))
        harness.transcriber.finish()

        let sourceSHA = try sha256(harness.audioURL)
        #expect(
            await waitUntil {
                harness.store.record(for: harness.episodeID)?.state == .completed
                    && harness.store.record(for: harness.episodeID)?.sourceFileSHA256 == sourceSHA
                    && !harness.store.hasActiveJob
            },
            sourceLocation: sourceLocation
        )
        let document = try #require(harness.store.document(for: harness.episodeID), sourceLocation: sourceLocation)
        #expect(document.segments.map(\.start) == [0, 10, 20, 30, 40, 50], sourceLocation: sourceLocation)
        #expect(
            !harness.fileStore.documentExists(relativePath: harness.priorRelativePath),
            sourceLocation: sourceLocation
        )
    }

    private func expectPriorTranscriptRestored(
        _ harness: ReplacementHarness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let record = try #require(harness.store.record(for: harness.episodeID), sourceLocation: sourceLocation)
        #expect(record.state == .completed, sourceLocation: sourceLocation)
        #expect(record.sourceFileSHA256 == "fixture-sha", sourceLocation: sourceLocation)
        #expect(record.transcriptRelativePath == harness.priorRelativePath, sourceLocation: sourceLocation)
        #expect(
            harness.store.document(for: harness.episodeID)?.text == Self.replacementPriorText,
            sourceLocation: sourceLocation
        )
    }

    private func replacementPartialRelativePath(
        _ harness: ReplacementHarness,
        audioURL: URL? = nil,
        modelIdentity: EpisodeTranscriptionModelIdentity? = nil
    ) throws -> String {
        let identity = modelIdentity ?? EpisodeTranscriptionModelIdentity(summary: modelSummary())
        return harness.fileStore.relativePath(
            episodeID: harness.episodeID,
            fingerprint: harness.fileStore.fingerprint(
                sourceFileSHA256: try sha256(audioURL ?? harness.audioURL),
                modelIdentifier: identity.modelIdentifier,
                modelVersion: identity.version,
                modelTreeSHA256: identity.treeSHA256
            )
        )
    }

    /// Every file in the episode's transcript directory, hidden ones included.
    private func episodeDocumentNames(_ harness: ReplacementHarness) throws -> [String] {
        let directory = harness.fileStore.transcriptsDirectory
            .appending(path: harness.fileStore.safeStem(harness.episodeID), directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func documentName(_ relativePath: String) -> String {
        URL(filePath: relativePath).lastPathComponent
    }

    private func tinyModelIdentity() -> EpisodeTranscriptionModelIdentity {
        EpisodeTranscriptionModelIdentity(summary: OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "c", count: 64)
        ))
    }

    private func replacementFailure(_ message: String) -> NSError {
        NSError(
            domain: "EpisodeTranscriptionStoreTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Completes a Whisper transcript, then starts an Apple Speech improve run
    /// preserving the prior transcript, whose stream is test-driven.
    private func makeImproveHarness(
        episodeID: String,
        secondAttemptStream: @escaping @MainActor (EpisodeTranscriptionRunRequest) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>
    ) async throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        store: EpisodeTranscriptionStore,
        fileStore: EpisodeTranscriptFileStore,
        priorModelIdentifier: String,
        priorRelativePath: String
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "improve audio \(episodeID)")
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, attempt in
            attempt == 1
                ? FakeEpisodeTranscriber().transcribe(request)
                : secondAttemptStream(request)
        }
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: fileStore,
            failureEnvironment: { .foreground }
        )
        let episode = makeEpisode(episodeID: episodeID)
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        let summary = modelSummary()
        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )
        _ = await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed && !store.hasActiveJob
        }
        guard let priorRecord = store.record(for: episode.episodeID),
              priorRecord.state == .completed,
              let priorRelativePath = priorRecord.transcriptRelativePath
        else {
            throw ImproveHarnessError.priorTranscriptNeverCompleted
        }
        let priorModelIdentifier = priorRecord.modelIdentifier

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            priorCompletedTranscript: .preserve,
            modelContext: context
        )
        // The prior-transcript snapshot is captured just before the improve
        // attempt reaches the transcriber; waiting here keeps the restore
        // paths deterministic for the caller.
        _ = await waitUntil { transcriber.requests.count == 2 }

        return (context, episode, store, fileStore, priorModelIdentifier, priorRelativePath)
    }

    private func makeAppleRunHarness(
        episodeID: String,
        stream: @escaping @MainActor (EpisodeTranscriptionRunRequest) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>
    ) throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        audioURL: URL,
        store: EpisodeTranscriptionStore
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(
            in: temporaryDirectory,
            contents: "Apple Speech audio \(episodeID)"
        )
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            stream(request)
        }
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { .foreground }
        )
        let episode = makeEpisode(episodeID: episodeID)
        return (context, episode, completedDownloadRecord(episode: episode), audioURL, store)
    }

    private func modelSummary() -> OpenCastWhisperModelInstalledSummary {
        OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            version: OpenCastWhisperModel.largeV3.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "b", count: 64)
        )
    }

    @Test("record(for:) matches a linear scan after load")
    func recordLookupMatchesLinearScan() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for index in 1...3 {
            context.insert(EpisodeTranscriptRecord(
                episodeID: "index-eq-\(index)",
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: "https://example.com/index-eq-\(index).mp3",
                sourceFileByteCount: 3,
                sourceFileSHA256: "abc",
                modelIdentifier: "openai_whisper-tiny.en",
                modelVersion: "20260701_75MB-v1",
                modelTreeSHA256: "60d71f9a",
                state: .failed,
                audioDuration: 60,
                completedDuration: 0,
                checkpointCount: 0,
                transcriptRelativePath: nil
            ))
        }
        try context.save()
        let store = EpisodeTranscriptionStore(transcriber: FakeEpisodeTranscriber())

        store.load(modelContext: context)

        for episodeID in ["index-eq-1", "index-eq-2", "index-eq-3", "index-eq-missing"] {
            #expect(store.record(for: episodeID) === store.records.first { $0.episodeID == episodeID })
        }
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    private func completedDownloadRecord(episode: EpisodeListItemSnapshot) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            localRelativePath: "EpisodeDownloads/\(episode.episodeID).mp3",
            state: .completed,
            bytesReceived: 10,
            bytesExpected: 10
        )
    }

    private func writeAudioPlaceholder(in directory: URL, contents: String) throws -> URL {
        let url = directory.appending(path: UUID().uuidString).appendingPathExtension("mp3")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return OpenCastSHA256.hash(data)
    }
}

private enum ImproveHarnessError: Error {
    case priorTranscriptNeverCompleted
}

@MainActor
private struct ReplacementHarness {
    let context: ModelContext
    let episode: EpisodeListItemSnapshot
    let downloadRecord: EpisodeDownloadRecord
    let audioURL: URL
    let directory: URL
    let store: EpisodeTranscriptionStore
    let fileStore: EpisodeTranscriptFileStore
    let transcriber: ManualEpisodeTranscriber
    let priorRelativePath: String

    var episodeID: String {
        episode.episodeID
    }
}

enum ReplacementStop: CaseIterable, Sendable {
    case userCancel
    case hardFailure
}

enum ReplacementSetupFailure: CaseIterable, Sendable {
    case hashing
    case duration
}

enum ReplacementResumeMismatch: CaseIterable, Sendable {
    case otherBytes
    case otherModel
    case otherLanguage
    case otherDuration
}

enum DownloadDeletionScope: CaseIterable, Sendable {
    case single
    case all
}

enum InFlightReplacementWrite: CaseIterable, Sendable {
    case finalResultAcrossDownloadDeletion
    case pendingCheckpointFlushAcrossDownloadDeletion
    case finalResultAcrossRestart
}

enum ReplacementRestartStop: CaseIterable, Sendable {
    case userCancel
    case interruption
}

/// Where a local run admitted during a remote import's document write has
/// got to when that write comes back.
enum RemoteImportOverlap: CaseIterable, Sendable {
    case runInSetup
    case runTranscribing
}

/// Holds the first document write (or read, on the read hook) that reaches
/// it after `arm()` until `release()`, so a test can act while that caller
/// is suspended in it.
nonisolated private final class DocumentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private var heldPath: String?
    private var heldContinuation: CheckedContinuation<Void, Never>?

    var heldRelativePath: String? {
        lock.withLock { heldPath }
    }

    func arm() {
        lock.withLock { isArmed = true }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isArmed = false
            let continuation = heldContinuation
            heldContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func hold(_ relativePath: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let holds = lock.withLock { () -> Bool in
                guard isArmed else {
                    return false
                }
                isArmed = false
                heldPath = relativePath
                heldContinuation = continuation
                return true
            }
            if !holds {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func appleImproveIdentity() -> EpisodeTranscriptionModelIdentity {
    EpisodeTranscriptionModelIdentity(
        modelIdentifier: "apple-speech-transcriber.en_US",
        version: "iOS 26 test",
        treeSHA256: "asset-status-installed-en_US"
    )
}

private func neverFinishingStream() -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.progress(EpisodeTranscriptionProgress(
            audioDuration: 60,
            completedDuration: 1,
            checkpointCount: 0,
            currentWindowIndex: 0,
            currentText: nil
        )))
    }
}

private func failingStream(
    message: String
) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: NSError(
            domain: "EpisodeTranscriptionStoreTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

private func coreMLError() -> NSError {
    NSError(
        domain: "com.apple.CoreML",
        code: 0,
        userInfo: [
            NSLocalizedDescriptionKey: "Unable to compute the asynchronous prediction using ML Program. It can be an invalid input data or broken/unsupported model."
        ]
    )
}

private final class FakeEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var lastRequest: EpisodeTranscriptionRunRequest?
    let resumedSegmentStart: TimeInterval
    let emittedSegments: [OpenCastTranscriptSegment]?

    init(
        resumedSegmentStart: TimeInterval = 0,
        emittedSegments: [OpenCastTranscriptSegment]? = nil
    ) {
        self.resumedSegmentStart = resumedSegmentStart
        self.emittedSegments = emittedSegments
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            let start = request.resumeStart ?? resumedSegmentStart
            let segments = emittedSegments ?? [
                OpenCastTranscriptSegment(
                    id: 0,
                    start: start,
                    end: start + 2,
                    text: "hello transcript",
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                ),
                OpenCastTranscriptSegment(
                    id: 1,
                    start: start + 2,
                    end: start + 4,
                    text: "from fake events",
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                )
            ]
            continuation.yield(.progress(EpisodeTranscriptionProgress(
                audioDuration: 60,
                completedDuration: start,
                checkpointCount: 0,
                currentWindowIndex: 0,
                currentText: nil
            )))
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: 1,
                audioDuration: 60,
                completedDuration: segments.first?.end ?? start,
                segments: [segments[0]],
                text: segments[0].text
            )))
            continuation.yield(.finished(OpenCastTranscriptionResult(
                modelIdentifier: request.modelIdentifier,
                languageCode: request.languageCode,
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                timings: OpenCastTranscriptionTimings(
                    audioDuration: 60,
                    modelLoading: 1,
                    audioLoading: 1,
                    transcription: 2,
                    fullPipeline: 4,
                    realTimeFactor: 0.03,
                    decodingFallbackCount: 1,
                    decodingFallback: 0.5,
                    decodingWindowCount: 2
                )
            )))
            continuation.finish()
        }
    }

    func unload() async {
    }
}

/// Event pacing under test control: the stream stays open until the test
/// finishes it, so checkpoint cadence and kill points are deterministic.
private final class ManualEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation?
    private var recordedRequests: [EpisodeTranscriptionRunRequest] = []

    var isStreaming: Bool {
        lock.withLock { continuation != nil }
    }

    var lastRequest: EpisodeTranscriptionRunRequest? {
        lock.withLock { recordedRequests.last }
    }

    var requestCount: Int {
        lock.withLock { recordedRequests.count }
    }

    var unloadCount: Int {
        lock.withLock { recordedUnloadCount }
    }

    private var recordedUnloadCount = 0

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                recordedRequests.append(request)
                self.continuation = continuation
            }
        }
    }

    func emit(_ event: EpisodeTranscriptionRunEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }

    func fail(with error: any Error) {
        lock.withLock { continuation }?.finish(throwing: error)
    }

    func unload() async {
        lock.withLock { recordedUnloadCount += 1 }
    }
}

private final class CoreMLFailingThenCompletingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requests: [EpisodeTranscriptionRunRequest] = []

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        guard requests.count > 1 else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: coreMLError())
            }
        }

        return FakeEpisodeTranscriber().transcribe(request)
    }

    func unload() async {
    }
}

private final class CheckpointThenCoreMLFailingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requests: [EpisodeTranscriptionRunRequest] = []

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        guard requests.count > 1 else {
            return AsyncThrowingStream { continuation in
                continuation.yield(.progress(EpisodeTranscriptionProgress(
                    audioDuration: 60,
                    completedDuration: 0,
                    checkpointCount: 0,
                    currentWindowIndex: 0,
                    currentText: nil
                )))
                continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                    index: 1,
                    audioDuration: 60,
                    completedDuration: 12,
                    segments: [
                        OpenCastTranscriptSegment(
                            id: 0,
                            start: 0,
                            end: 12,
                            text: "checkpoint before failure",
                            avgLogProbability: -0.1,
                            noSpeechProbability: 0.01
                        )
                    ],
                    text: "checkpoint before failure"
                )))
                continuation.finish(throwing: coreMLError())
            }
        }

        return FakeEpisodeTranscriber().transcribe(request)
    }

    func unload() async {
    }
}

private final class AlwaysCoreMLFailingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requests: [EpisodeTranscriptionRunRequest] = []

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: coreMLError())
        }
    }

    func unload() async {
    }
}

private final class CheckpointThenManualFailureTranscriber: EpisodeTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            continuation.yield(.progress(EpisodeTranscriptionProgress(
                audioDuration: 60,
                completedDuration: 0,
                checkpointCount: 0,
                currentWindowIndex: 0,
                currentText: nil
            )))
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: 1,
                audioDuration: 60,
                completedDuration: 12,
                segments: [
                    OpenCastTranscriptSegment(
                        id: 0,
                        start: 0,
                        end: 12,
                        text: "checkpoint before late failure",
                        avgLogProbability: -0.1,
                        noSpeechProbability: 0.01
                    )
                ],
                text: "checkpoint before late failure"
            )))
        }
    }

    func unload() async {
    }

    func failWithCoreML() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish(throwing: coreMLError())
    }
}

private final class BlockingThenCompletingEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        if requestCount == 1 {
            return AsyncThrowingStream { _ in }
        }

        return FakeEpisodeTranscriber().transcribe(request)
    }

    func unload() async {
    }
}

private final class RegressingCheckpointEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var lastRequest: EpisodeTranscriptionRunRequest?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(EpisodeTranscriptionProgress(
                audioDuration: 60,
                completedDuration: request.resumeStart ?? 0,
                checkpointCount: 1,
                currentWindowIndex: nil,
                currentText: nil
            )))
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: 1,
                audioDuration: 60,
                completedDuration: 4,
                segments: [
                    OpenCastTranscriptSegment(
                        id: 0,
                        start: 0,
                        end: 4,
                        text: "reported from the beginning again",
                        avgLogProbability: -0.1,
                        noSpeechProbability: 0.01
                    )
                ],
                text: "reported from the beginning again"
            )))
            continuation.finish()
        }
    }

    func unload() async {
    }
}

private final class SuspendingUnloadEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0
    var unloadCallCount = 0
    var isFirstUnloadSuspended = false
    private var firstUnloadContinuation: CheckedContinuation<Void, Never>?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.progress(EpisodeTranscriptionProgress(
                    audioDuration: 60,
                    completedDuration: 0,
                    checkpointCount: 0,
                    currentWindowIndex: 0,
                    currentText: nil
                )))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func unload() async {
        unloadCallCount += 1
        guard unloadCallCount == 1 else {
            return
        }

        isFirstUnloadSuspended = true
        await withCheckedContinuation { continuation in
            firstUnloadContinuation = continuation
        }
    }

    func releaseFirstUnload() {
        firstUnloadContinuation?.resume()
        firstUnloadContinuation = nil
    }
}
