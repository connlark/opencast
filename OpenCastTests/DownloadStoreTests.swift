import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode downloads")
struct DownloadStoreTests {
    @Test("Download store completes progress and deletes local files")
    func downloadStoreCompletesProgressAndDeletesLocalFiles() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [Data("abc".utf8), Data("def".utf8)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "download-complete")

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        let relativePath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(record.bytesReceived == 6)
        #expect(record.bytesExpected == 6)
        #expect(fileStore.fileExists(relativePath: relativePath))

        store.deleteDownload(record, modelContext: context)

        #expect(store.record(for: episode.episodeID) == nil)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        #expect(fileStore.fileExists(relativePath: relativePath) == false)
    }

    @Test("ensureCompletedDownload returns a completed record and self-heals a missing file")
    func ensureCompletedDownloadSelfHealsMissingFile() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [Data("abc".utf8)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "ensure-missing-file")

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)
        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .completed)

        let ensured = try await store.ensureCompletedDownload(
            for: episode,
            modelContext: context,
            onWaitStarted: { try Task.checkCancellation() }
        )
        #expect(ensured === record)

        let relativePath = try #require(record.localRelativePath)
        try FileManager.default.removeItem(at: fileStore.fileURL(relativePath: relativePath))

        await #expect(throws: DownloadStore.CompletedDownloadError.fileMissing) {
            _ = try await store.ensureCompletedDownload(
                for: episode,
                modelContext: context,
                onWaitStarted: { try Task.checkCancellation() }
            )
        }
        #expect(store.record(for: episode.episodeID)?.state == .missing)
    }

    @Test("Cancel removes the download record and partial file")
    func cancelRemovesRecordAndPartialFile() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(downloader: HangingEpisodeAudioDownloader(), fileStore: fileStore)
        let episode = makeEpisode(episodeID: "download-cancel")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil { store.byteProgress(for: episode.episodeID)?.bytesReceived == 7 })

        store.cancelDownload(episodeID: episode.episodeID, modelContext: context)

        #expect(store.record(for: episode.episodeID) == nil)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        let relativePath = fileStore.relativePath(
            episodeID: episode.episodeID,
            sourceAudioURL: URL(string: episode.audioURL!)!
        )
        #expect(fileStore.fileExists(relativePath: relativePath) == false)
    }

    @Test("Active progress stays in memory until a durable transition")
    func activeProgressDoesNotSaveEveryTick() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(
            downloader: HangingEpisodeAudioDownloader(),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "transient-download-progress")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil { store.byteProgress(for: episode.episodeID)?.bytesReceived == 7 })

        // Ticks surface through the transient accessor; the record and the
        // context stay untouched so autosave has nothing to persist (and the
        // remote-change reload cascade never fires mid-download).
        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.bytesReceived == 0)
        #expect(store.byteProgress(for: episode.episodeID)?.bytesExpected == 100)
        #expect(context.hasChanges == false)

        store.cancelDownload(episodeID: episode.episodeID, modelContext: context)
    }

    @Test("Reconcile marks interrupted and missing downloads")
    func reconcileMarksInterruptedAndMissingDownloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(fileStore: fileStore)
        let sourceURL = URL(string: "https://example.com/audio.mp3")!

        context.insert(
            EpisodeDownloadRecord(
                episodeID: "interrupted",
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: sourceURL.absoluteString,
                localRelativePath: fileStore.relativePath(episodeID: "interrupted", sourceAudioURL: sourceURL),
                state: .downloading
            )
        )
        context.insert(
            EpisodeDownloadRecord(
                episodeID: "missing",
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: sourceURL.absoluteString,
                localRelativePath: fileStore.relativePath(episodeID: "missing", sourceAudioURL: sourceURL),
                state: .completed,
                bytesReceived: 100,
                bytesExpected: 100
            )
        )
        try context.save()

        store.load(modelContext: context)

        #expect(store.record(for: "interrupted")?.state == .failed)
        #expect(store.record(for: "interrupted")?.errorMessage == EpisodeDownloadError.interrupted.localizedDescription)
        #expect(store.record(for: "missing")?.state == .missing)
        #expect(store.record(for: "missing")?.errorMessage == EpisodeDownloadError.missingDownloadedFile.localizedDescription)
    }

    @Test("URLSession downloader can copy a local file without network")
    func urlSessionDownloaderCopiesLocalFile() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let sourceURL = temporaryDirectory.appending(path: "source.mp3")
        let destinationURL = temporaryDirectory.appending(path: "destination.partial")
        let data = Data("local audio data".utf8)
        try data.write(to: sourceURL)
        let downloader = URLSessionEpisodeAudioDownloader()
        var progressEvents: [(Int64, Int64?)] = []

        try await downloader.download(
            from: sourceURL,
            to: destinationURL,
            resume: nil,
            onResponseMetadata: { _ in },
            progress: { bytesReceived, bytesExpected in
                progressEvents.append((bytesReceived, bytesExpected))
            }
        )

        #expect(try Data(contentsOf: destinationURL) == data)
        #expect(progressEvents.last?.0 == Int64(data.count))
        #expect(progressEvents.last?.1 == Int64(data.count))
    }

    @Test("Primary playback source remains remote when a download exists")
    func primaryPlaybackSourceRemainsRemoteWhenDownloadExists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloadStore
        )
        let episode = makeEpisode(episodeID: "playback-policy")
        let downloadRecord = try insertCompletedDownload(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: URL(string: episode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try context.save()
        downloadStore.load(modelContext: context)

        let streamEpisode = try appModel.resolvedPlaybackEpisode(for: episode, source: .stream, modelContext: context)
        let downloadedEpisode = try appModel.resolvedPlaybackEpisode(
            for: episode,
            source: .downloaded(downloadRecord),
            modelContext: context
        )

        #expect(streamEpisode.audioURL?.absoluteString == episode.audioURL)
        #expect(downloadedEpisode.audioURL?.isFileURL == true)
        #expect(downloadedEpisode.title == episode.title)
        #expect(downloadedEpisode.artworkURL?.absoluteString == episode.artworkURL)
    }

    @Test("Downloaded playback marks missing files before throwing")
    func downloadedPlaybackMarksMissingFilesBeforeThrowing() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloadStore
        )
        let episode = makeEpisode(episodeID: "missing-at-playback")
        let downloadRecord = try insertCompletedDownload(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: URL(string: episode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try context.save()
        downloadStore.load(modelContext: context)
        try fileStore.removeFile(relativePath: downloadRecord.localRelativePath)

        do {
            _ = try appModel.resolvedPlaybackEpisode(
                for: episode,
                source: .downloaded(downloadRecord),
                modelContext: context
            )
            Issue.record("Expected missing downloaded file to throw.")
        } catch EpisodeDownloadError.missingDownloadedFile {
        } catch {
            Issue.record("Expected missing downloaded file, got \(error).")
        }

        #expect(downloadRecord.state == .missing)
        #expect(downloadRecord.errorMessage == EpisodeDownloadError.missingDownloadedFile.localizedDescription)
        #expect(downloadStore.record(for: episode.episodeID)?.state == .missing)
    }

    @Test("Download setup errors are scoped to the failed episode")
    func downloadSetupErrorsAreScopedToFailedEpisode() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = DownloadStore()
        let failedEpisode = makeEpisode(episodeID: "missing-audio", audioURL: nil)
        let unrelatedEpisode = makeEpisode(episodeID: "playable-audio")

        store.startDownload(for: failedEpisode, modelContext: context)

        let expectedMessage = EpisodeDownloadError.invalidAudioURL.localizedDescription
        #expect(store.lastErrorMessage == expectedMessage)
        #expect(store.lastErrorMessage(for: failedEpisode.episodeID) == expectedMessage)
        #expect(store.lastErrorMessage(for: unrelatedEpisode.episodeID) == nil)
    }

    @Test("Unsubscribe removes only downloads for that feed")
    func unsubscribeRemovesOnlyDownloadsForThatFeed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let libraryStore = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let removedFeedURL = "https://example.com/removed.xml"
        let keptFeedURL = "https://example.com/kept.xml"
        let removedPath = try insertFeedAndDownload(
            feedURL: removedFeedURL,
            episodeID: "removed-episode",
            fileStore: fileStore,
            context: context
        )
        let keptPath = try insertFeedAndDownload(
            feedURL: keptFeedURL,
            episodeID: "kept-episode",
            fileStore: fileStore,
            context: context
        )
        try context.save()
        await libraryStore.load(modelContext: context)
        downloadStore.load(modelContext: context)

        await libraryStore.unsubscribe(
            feedURL: removedFeedURL,
            modelContext: context,
            downloadStore: downloadStore
        )

        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).map(\.podcastID) == [keptFeedURL])
        #expect(fileStore.fileExists(relativePath: removedPath) == false)
        #expect(fileStore.fileExists(relativePath: keptPath))
        #expect(libraryStore.subscriptions.map(\.feedURL) == [keptFeedURL])
        #expect(libraryStore.episodes(forPodcastID: keptFeedURL).map(\.episodeID) == ["kept-episode"])
    }

    @Test("Clear Automatic Caches leaves explicit downloads intact")
    func clearAutomaticCachesLeavesExplicitDownloadsIntact() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        )
        let downloadStore = DownloadStore(fileStore: fileStore)
        let episode = makeEpisode(episodeID: "clear-cache-download")
        let downloadRecord = try insertCompletedDownload(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: URL(string: episode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try context.save()
        downloadStore.load(modelContext: context)
        try writeCacheFixture(in: cacheController.feedCacheDirectory, fileName: "feed.cache")
        try writeCacheFixture(in: cacheController.artworkCacheDirectory, fileName: "artwork.cache")

        cacheController.refreshSummaries()
        await cacheController.waitForPendingMaintenance()
        #expect(cacheController.feedCacheSummary.byteCount > 0)
        #expect(cacheController.artworkCacheSummary.byteCount > 0)

        cacheController.clearCaches()
        await cacheController.waitForPendingMaintenance()

        #expect(cacheController.feedCacheSummary.byteCount == 0)
        #expect(cacheController.artworkCacheSummary.byteCount == 0)
        let relativePath = try #require(downloadRecord.localRelativePath)
        #expect(downloadStore.record(for: episode.episodeID)?.episodeID == downloadRecord.episodeID)
        #expect(fileStore.fileExists(relativePath: relativePath))
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).map(\.episodeID) == [episode.episodeID])
    }

    @Test("Delete All Downloads leaves automatic caches intact")
    func deleteAllDownloadsLeavesAutomaticCachesIntact() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        )
        let downloadStore = DownloadStore(fileStore: fileStore)
        let firstEpisode = makeEpisode(episodeID: "delete-all-downloads-first")
        let secondEpisode = makeEpisode(episodeID: "delete-all-downloads-second")
        let firstRecord = try insertCompletedDownload(
            episodeID: firstEpisode.episodeID,
            podcastID: firstEpisode.podcastID,
            sourceAudioURL: URL(string: firstEpisode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        let secondRecord = try insertCompletedDownload(
            episodeID: secondEpisode.episodeID,
            podcastID: secondEpisode.podcastID,
            sourceAudioURL: URL(string: secondEpisode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        let firstRelativePath = try #require(firstRecord.localRelativePath)
        let secondRelativePath = try #require(secondRecord.localRelativePath)
        try context.save()
        downloadStore.load(modelContext: context)
        try writeCacheFixture(in: cacheController.feedCacheDirectory, fileName: "feed.cache")
        try writeCacheFixture(in: cacheController.artworkCacheDirectory, fileName: "artwork.cache")

        cacheController.refreshSummaries()
        await cacheController.waitForPendingMaintenance()
        #expect(cacheController.feedCacheSummary.byteCount > 0)
        #expect(cacheController.artworkCacheSummary.byteCount > 0)

        downloadStore.deleteAllDownloads(modelContext: context)
        cacheController.refreshSummaries()
        await cacheController.waitForPendingMaintenance()

        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        #expect(downloadStore.completedDownloadCount == 0)
        #expect(fileStore.fileExists(relativePath: firstRelativePath) == false)
        #expect(fileStore.fileExists(relativePath: secondRelativePath) == false)
        #expect(cacheController.feedCacheSummary.byteCount > 0)
        #expect(cacheController.artworkCacheSummary.byteCount > 0)
    }

    @Test("Batch deletion preserves an earlier failure after a later success")
    func batchDeletionPreservesEarlierFailure() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(fileStore: fileStore)
        let lockedDirectory = fileStore.downloadsDirectory.appending(
            path: "locked",
            directoryHint: .isDirectory
        )
        let failedFileURL = lockedDirectory.appending(path: "failed.mp3")
        let failedRelativePath = "\(EpisodeDownloadFileStore.directoryName)/locked/failed.mp3"

        try fileStore.prepareDownloadsDirectory()
        try FileManager.default.createDirectory(
            at: lockedDirectory,
            withIntermediateDirectories: true
        )
        try Data("undeletable".utf8).write(to: failedFileURL, options: .atomic)

        let failedRecord = EpisodeDownloadRecord(
            episodeID: "batch-delete-failure",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/failure.mp3",
            localRelativePath: failedRelativePath,
            state: .completed,
            bytesReceived: 11,
            bytesExpected: 11
        )
        let succeededRecord = try insertCompletedDownload(
            episodeID: "batch-delete-success",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: URL(string: "https://example.com/success.mp3")!,
            fileStore: fileStore,
            context: context
        )
        let succeededRelativePath = try #require(succeededRecord.localRelativePath)
        context.insert(failedRecord)
        try context.save()
        store.load(modelContext: context)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: lockedDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: lockedDirectory.path
            )
        }

        store.deleteDownloads([failedRecord, succeededRecord], modelContext: context)

        #expect(store.record(for: failedRecord.episodeID) != nil)
        #expect(store.record(for: succeededRecord.episodeID) == nil)
        #expect(FileManager.default.fileExists(atPath: failedFileURL.path))
        #expect(fileStore.fileExists(relativePath: succeededRelativePath) == false)
        #expect(store.lastErrorMessage != nil)
        #expect(store.lastErrorMessage(for: failedRecord.episodeID) == store.lastErrorMessage)
    }

    @Test("Per-podcast storage cleanup removes completed downloads only")
    func perPodcastStorageCleanupKeepsActiveRecords() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloadStore = DownloadStore(fileStore: fileStore)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloadStore
        )
        let completedEpisode = makeEpisode(episodeID: "podcast-cleanup-completed")
        let pausedEpisode = makeEpisode(episodeID: "podcast-cleanup-paused")
        _ = try insertCompletedDownload(
            episodeID: completedEpisode.episodeID,
            podcastID: completedEpisode.podcastID,
            sourceAudioURL: URL(string: completedEpisode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try fileStore.prepareDownloadsDirectory()
        try Data("paused".utf8).write(
            to: fileStore.pausedPartialFileURL(episodeID: pausedEpisode.episodeID),
            options: .atomic
        )
        context.insert(EpisodeDownloadRecord(
            episodeID: pausedEpisode.episodeID,
            podcastID: pausedEpisode.podcastID,
            sourceAudioURL: pausedEpisode.audioURL!,
            state: .paused,
            bytesReceived: 6,
            bytesExpected: 100
        ))
        try context.save()
        downloadStore.load(modelContext: context)

        try appModel.deleteCompletedDownloads(
            forPodcastID: completedEpisode.podcastID,
            modelContext: context
        )

        #expect(downloadStore.record(for: completedEpisode.episodeID) == nil)
        #expect(downloadStore.record(for: pausedEpisode.episodeID)?.state == .paused)
        #expect(FileManager.default.fileExists(
            atPath: fileStore.pausedPartialFileURL(episodeID: pausedEpisode.episodeID).path
        ))
    }

    @Test("Pausing preserves a stable partial and wakes download waiters")
    func pausingPreservesPartialAndWakesWaiters() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = ResumableGatedEpisodeAudioDownloader()
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "pause-download")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil { store.byteProgress(for: episode.episodeID)?.bytesReceived == 3 })
        let waiter = Task {
            try await store.waitForDownload(episodeID: episode.episodeID)
        }

        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await waiter.value

        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .paused)
        #expect(record.bytesReceived == 3)
        #expect(record.errorMessage == nil)
        #expect(try Data(contentsOf: fileStore.pausedPartialFileURL(episodeID: episode.episodeID)) == Data("abc".utf8))
    }

    @Test("Pausing a real URLSession stream treats URL cancellation as a pause")
    func pausingURLSessionStreamPreservesPartial() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let receivedByteCount = 64 * 1_024
        HangingDownloadTestURLProtocol.configure(
            body: Data(repeating: 0x5A, count: receivedByteCount),
            expectedByteCount: receivedByteCount * 2
        )
        let store = DownloadStore(
            downloader: URLSessionEpisodeAudioDownloader(session: session),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "url-session-pause")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil {
            store.byteProgress(for: episode.episodeID)?.bytesReceived == Int64(receivedByteCount)
        })

        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        #expect(store.record(for: episode.episodeID)?.state == .paused)
        #expect(store.record(for: episode.episodeID)?.bytesReceived == Int64(receivedByteCount))
        #expect(try fileStore.fileSize(
            at: fileStore.pausedPartialFileURL(episodeID: episode.episodeID)
        ) == Int64(receivedByteCount))
    }

    @Test("Paused downloads survive reload and resume from the on-disk offset")
    func pausedDownloadsSurviveReloadAndResume() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = ResumableGatedEpisodeAudioDownloader()
        let firstStore = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "resume-download")

        firstStore.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil { firstStore.byteProgress(for: episode.episodeID)?.bytesReceived == 3 })
        firstStore.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await firstStore.waitForDownload(episodeID: episode.episodeID)

        let relaunchedStore = DownloadStore(downloader: downloader, fileStore: fileStore)
        relaunchedStore.load(modelContext: context)
        #expect(relaunchedStore.record(for: episode.episodeID)?.state == .paused)

        relaunchedStore.resumeDownload(episodeID: episode.episodeID, modelContext: context)
        try await relaunchedStore.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(relaunchedStore.record(for: episode.episodeID))
        let relativePath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(record.bytesReceived == 6)
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath)) == Data("abcdef".utf8))
        #expect(downloader.resumeContexts().last == EpisodeDownloadResumeContext(
            offset: 3,
            entityTag: "resume-etag",
            lastModified: "Wed, 01 Jul 2026 00:00:00 GMT"
        ))
    }

    @Test("A transient resume failure preserves newly received partial bytes")
    func transientResumeFailurePreservesPartial() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloader = ResumeFailingOnceEpisodeAudioDownloader()
        let store = DownloadStore(
            downloader: downloader,
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "resume-failure")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil { store.byteProgress(for: episode.episodeID)?.bytesReceived == 3 })
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        store.resumeDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let expectedError = URLError(.notConnectedToInternet).localizedDescription
        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .failed)
        #expect(record.bytesReceived == 4)
        #expect(record.errorMessage == expectedError)
        #expect(store.lastErrorMessage(for: episode.episodeID) == expectedError)
        #expect(store.activeDownloadCount == 0)
        #expect(store.failedOrMissingRecords.map(\.episodeID) == [episode.episodeID])
        #expect(try Data(
            contentsOf: fileStore.pausedPartialFileURL(episodeID: episode.episodeID)
        ) == Data("abcd".utf8))

        store.retryDownload(record, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let completedRecord = try #require(store.record(for: episode.episodeID))
        let relativePath = try #require(completedRecord.localRelativePath)
        #expect(completedRecord.state == .completed)
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath)) == Data("abcdef".utf8))
        #expect(downloader.resumeOffsets() == [3, 4])
    }

    @Test("Reconcile adopts interrupted partials and rejects missing paused files")
    func reconcileAdoptsInterruptedPartialAndRejectsMissingPausedFile() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        try fileStore.prepareDownloadsDirectory()
        try Data("partial audio".utf8).write(
            to: fileStore.temporaryFileURL(episodeID: "adopt-partial", token: "latest"),
            options: .atomic
        )
        try Data("stable partial".utf8).write(
            to: fileStore.pausedPartialFileURL(episodeID: "adopt-stable-partial"),
            options: .atomic
        )
        try Data("resume crash partial".utf8).write(
            to: fileStore.temporaryFileURL(episodeID: "paused-resume-crash", token: "resume-token"),
            options: .atomic
        )
        let completedBeforeStateSaveURL = URL(string: "https://example.com/completed-before-save.mp3")!
        let completedBeforeStateSavePath = fileStore.relativePath(
            episodeID: "completed-before-state-save",
            sourceAudioURL: completedBeforeStateSaveURL
        )
        try Data("completed audio".utf8).write(
            to: fileStore.fileURL(relativePath: completedBeforeStateSavePath),
            options: .atomic
        )
        context.insert(EpisodeDownloadRecord(
            episodeID: "adopt-partial",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/adopt.mp3",
            state: .downloading,
            bytesReceived: 1,
            bytesExpected: 100
        ))
        context.insert(EpisodeDownloadRecord(
            episodeID: "adopt-stable-partial",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/stable.mp3",
            state: .downloading,
            bytesReceived: 1,
            bytesExpected: 100
        ))
        context.insert(EpisodeDownloadRecord(
            episodeID: "completed-before-state-save",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: completedBeforeStateSaveURL.absoluteString,
            localRelativePath: completedBeforeStateSavePath,
            state: .downloading,
            bytesReceived: 1,
            bytesExpected: 100
        ))
        context.insert(EpisodeDownloadRecord(
            episodeID: "paused-resume-crash",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/resume-crash.mp3",
            state: .paused,
            bytesReceived: 1,
            bytesExpected: 100
        ))
        context.insert(EpisodeDownloadRecord(
            episodeID: "missing-paused",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/missing.mp3",
            state: .paused,
            bytesReceived: 12,
            bytesExpected: 100
        ))
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        store.load(modelContext: context)

        #expect(store.record(for: "adopt-partial")?.state == .paused)
        #expect(store.record(for: "adopt-partial")?.bytesReceived == 13)
        #expect(FileManager.default.fileExists(
            atPath: fileStore.pausedPartialFileURL(episodeID: "adopt-partial").path
        ))
        #expect(store.record(for: "adopt-stable-partial")?.state == .paused)
        #expect(store.record(for: "adopt-stable-partial")?.bytesReceived == 14)
        #expect(store.record(for: "completed-before-state-save")?.state == .completed)
        #expect(store.record(for: "completed-before-state-save")?.bytesReceived == 15)
        #expect(store.record(for: "completed-before-state-save")?.bytesExpected == 15)
        #expect(store.record(for: "paused-resume-crash")?.state == .paused)
        #expect(store.record(for: "paused-resume-crash")?.bytesReceived == 20)
        #expect(try Data(
            contentsOf: fileStore.pausedPartialFileURL(episodeID: "paused-resume-crash")
        ) == Data("resume crash partial".utf8))
        #expect(store.record(for: "missing-paused")?.state == .failed)
        #expect(store.record(for: "missing-paused")?.errorMessage == EpisodeDownloadError.interrupted.localizedDescription)
    }

    @Test("Reconcile preserves a paused partial when its size cannot be read")
    func reconcilePreservesUnreadablePausedPartial() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let episodeID = "unreadable-paused-partial"
        let partialData = Data("preserve this partial".utf8)
        try fileStore.prepareDownloadsDirectory()
        let partialURL = fileStore.pausedPartialFileURL(episodeID: episodeID)
        try partialData.write(to: partialURL, options: .atomic)
        context.insert(EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/unreadable.mp3",
            state: .paused,
            bytesReceived: Int64(partialData.count),
            bytesExpected: 100
        ))
        try context.save()

        let fileManager = FileManager.default
        let directoryPath = fileStore.downloadsDirectory.path
        let originalPermissions = try #require(
            fileManager.attributesOfItem(atPath: directoryPath)[.posixPermissions]
        )
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: directoryPath)
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: directoryPath
            )
        }

        let store = DownloadStore(fileStore: fileStore)
        store.load(modelContext: context)
        #expect(store.lastErrorMessage != nil)
        #expect(store.record(for: episodeID)?.state == .paused)
        #expect(store.record(for: episodeID)?.bytesReceived == Int64(partialData.count))
        #expect(store.activeDownloadCount == 1)

        try fileManager.setAttributes(
            [.posixPermissions: originalPermissions],
            ofItemAtPath: directoryPath
        )
        let storedRecords = try context.fetch(FetchDescriptor<EpisodeDownloadRecord>())
        #expect(storedRecords.contains { $0.episodeID == episodeID && $0.state == .paused })
        #expect(try Data(contentsOf: partialURL) == partialData)

        store.load(modelContext: context)
        #expect(store.record(for: episodeID)?.state == .paused)
        #expect(store.record(for: episodeID)?.bytesReceived == Int64(partialData.count))
    }

    @Test("Retry All restarts failed and missing records once and active count includes paused")
    func retryAllRestartsEligibleRecordsAndCountsActiveStates() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(downloader: HangingEpisodeAudioDownloader(), fileStore: fileStore)
        for (episodeID, state) in [("failed-retry", EpisodeDownloadState.failed), ("missing-retry", .missing)] {
            context.insert(EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: "https://example.com/\(episodeID).mp3",
                state: state,
                errorMessage: "Retry me"
            ))
        }
        try context.save()
        store.load(modelContext: context)

        store.retryAllFailedDownloads(modelContext: context)
        #expect(await waitUntil {
            store.byteProgress(for: "failed-retry")?.bytesReceived == 7
                && store.byteProgress(for: "missing-retry")?.bytesReceived == 7
        })
        store.retryAllFailedDownloads(modelContext: context)

        #expect(store.failedOrMissingRecords.isEmpty)
        #expect(store.activeDownloadCount == 2)
        store.pauseDownload(episodeID: "failed-retry", modelContext: context)
        #expect(await waitUntil { store.record(for: "failed-retry")?.state == .paused })
        #expect(store.activeDownloadCount == 2)

        store.cancelDownload(episodeID: "failed-retry", modelContext: context)
        store.cancelDownload(episodeID: "missing-retry", modelContext: context)
    }

    @Test("Auto-delete preference persists and played downloads are swept only when enabled")
    func autoDeletePreferencePersistsAndControlsSweep() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let appModel = OpenCastAppModel(library: library, downloads: downloadStore)
        let episode = makeEpisode(episodeID: "auto-delete-played")
        let record = try insertCompletedDownload(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: URL(string: episode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        let relativePath = try #require(record.localRelativePath)
        try context.save()
        downloadStore.load(modelContext: context)
        #expect(library.markEpisodePlayed(episode, modelContext: context))

        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)
        #expect(downloadStore.record(for: episode.episodeID) != nil)

        #expect(downloadStore.setAutoDeletesPlayedDownloads(true, modelContext: context))
        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)
        #expect(downloadStore.record(for: episode.episodeID) == nil)
        #expect(fileStore.fileExists(relativePath: relativePath) == false)

        let relaunchedStore = DownloadStore(fileStore: fileStore)
        relaunchedStore.load(modelContext: context)
        #expect(relaunchedStore.autoDeletesPlayedDownloads)
    }

    @Test("Auto-delete keeps the currently playing download")
    func autoDeleteSkipsCurrentlyPlayingDownload() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloadStore = DownloadStore(fileStore: fileStore)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let appModel = OpenCastAppModel(library: library, downloads: downloadStore)
        let episode = makeEpisode(episodeID: "auto-delete-playing")
        let record = try insertCompletedDownload(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: URL(string: episode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try context.save()
        downloadStore.load(modelContext: context)
        #expect(library.markEpisodePlayed(episode, modelContext: context))
        #expect(downloadStore.setAutoDeletesPlayedDownloads(true, modelContext: context))
        try appModel.playDownloadedEpisode(
            episode,
            downloadRecord: record,
            modelContext: context
        )

        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)

        #expect(downloadStore.record(for: episode.episodeID)?.state == .completed)
        appModel.playback.unload()
    }

    @Test("Auto-delete keeps downloads queued for an ad-free pass")
    func autoDeleteSkipsPassQueuedDownload() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloadStore = DownloadStore(
            downloader: HangingEpisodeAudioDownloader(),
            fileStore: fileStore
        )
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let appModel = OpenCastAppModel(library: library, downloads: downloadStore)
        let queuedEpisode = makeEpisode(episodeID: "auto-delete-pass-queued")
        let blocker = makeEpisode(episodeID: "auto-delete-pass-blocker")
        _ = try insertCompletedDownload(
            episodeID: queuedEpisode.episodeID,
            podcastID: queuedEpisode.podcastID,
            sourceAudioURL: URL(string: queuedEpisode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try context.save()
        downloadStore.load(modelContext: context)
        #expect(library.markEpisodePlayed(queuedEpisode, modelContext: context))
        #expect(downloadStore.setAutoDeletesPlayedDownloads(true, modelContext: context))

        appModel.startAdFreePass(for: blocker, modelContext: context)
        #expect(await waitUntil { appModel.adFreePass.activeEpisodeID == blocker.episodeID })
        appModel.startAdFreePass(for: queuedEpisode, modelContext: context)
        #expect(await waitUntil {
            if case .queued = appModel.adFreePass.queueStatus(for: queuedEpisode.episodeID) {
                return true
            }
            return false
        })

        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)

        #expect(downloadStore.record(for: queuedEpisode.episodeID)?.state == .completed)
        appModel.adFreePass.reset()
        downloadStore.cancelDownload(episodeID: blocker.episodeID, modelContext: context)
    }

    @Test("Auto-delete keeps downloads used by an active transcription")
    func autoDeleteSkipsActivelyTranscribingDownload() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: HangingAutoDeleteEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let appModel = OpenCastAppModel(
            library: library,
            downloads: downloadStore,
            transcriptions: transcriptions
        )
        let episode = makeEpisode(episodeID: "auto-delete-transcribing")
        let record = try insertCompletedDownload(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: URL(string: episode.audioURL!)!,
            fileStore: fileStore,
            context: context
        )
        try context.save()
        downloadStore.load(modelContext: context)
        #expect(library.markEpisodePlayed(episode, modelContext: context))
        #expect(downloadStore.setAutoDeletesPlayedDownloads(true, modelContext: context))
        let localFileURL = try #require(downloadStore.localFileURL(for: record))
        transcriptions.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: localFileURL,
            engine: .appleSpeech,
            modelIdentity: EpisodeTranscriptionModelIdentity(
                modelIdentifier: "apple-speech-transcriber.en_US",
                version: "iOS 26 test",
                treeSHA256: "installed-en-US"
            ),
            languageCode: "en-US",
            modelContext: context
        )
        #expect(await waitUntil {
            transcriptions.isActivelyTranscribing(episodeID: episode.episodeID)
        })

        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)

        #expect(downloadStore.record(for: episode.episodeID)?.state == .completed)
        transcriptions.cancelTranscription(episodeID: episode.episodeID, modelContext: context)
    }

    @Test("Pausing after a download completes leaves it completed")
    func pauseAfterFinalBytesLeavesCompletedRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let store = DownloadStore(
            downloader: CompletedBytesHangingEpisodeAudioDownloader(),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "pause-after-completion")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .downloading
                && store.byteProgress(for: episode.episodeID)?.bytesReceived == 8
        })
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        #expect(store.record(for: episode.episodeID)?.state == .completed)
    }

    @Test("Completed download persists the assembled-file hash and exposes source identity")
    func completedDownloadPersistsSourceIdentity() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [Data("abc".utf8), Data("def".utf8)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "identity-fresh")

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.sourceFileSHA256 == OpenCastSHA256.hash(Data("abcdef".utf8)))

        let identity = try #require(store.completedSourceIdentity(for: episode.episodeID))
        #expect(identity.sha256 == OpenCastSHA256.hash(Data("abcdef".utf8)))
        #expect(identity.byteCount == 6)
        #expect(identity.durationSeconds == nil)
    }

    @Test("Source identity invalidates when the local file drifts or disappears")
    func sourceIdentityInvalidatesOnFileDrift() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [Data("abcdef".utf8)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "identity-drift")

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)
        #expect(store.completedSourceIdentity(for: episode.episodeID) != nil)

        let record = try #require(store.record(for: episode.episodeID))
        let fileURL = try #require(store.localFileURL(for: record))
        try Data("replaced-with-longer-bytes".utf8).write(to: fileURL, options: .atomic)
        #expect(store.completedSourceIdentity(for: episode.episodeID) == nil)

        try FileManager.default.removeItem(at: fileURL)
        #expect(store.completedSourceIdentity(for: episode.episodeID) == nil)
    }

    @Test("Preexisting completed records without a hash expose no identity")
    func preexistingCompletedRecordWithoutHashExposesNoIdentity() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let store = DownloadStore(fileStore: fileStore)
        let sourceURL = URL(string: "https://example.com/legacy.mp3")!
        let relativePath = fileStore.relativePath(episodeID: "identity-legacy", sourceAudioURL: sourceURL)
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: fileURL, options: .atomic)
        context.insert(
            EpisodeDownloadRecord(
                episodeID: "identity-legacy",
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: sourceURL.absoluteString,
                localRelativePath: relativePath,
                state: .completed,
                bytesReceived: 6,
                bytesExpected: 6
            )
        )
        try context.save()
        store.load(modelContext: context)

        // The record predates hash persistence, so the identity is honestly
        // unavailable until something recomputes it from the file.
        #expect(store.completedSourceIdentity(for: "identity-legacy") == nil)
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        makeEpisode(episodeID: episodeID, audioURL: "https://example.com/\(episodeID).mp3")
    }

    private func makeEpisode(episodeID: String, audioURL: String?) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode",
            summary: nil,
            publishedAt: nil,
            duration: 120,
            audioURL: audioURL,
            artworkURL: "https://example.com/art.jpg",
            artworkPreview: nil,
            guid: episodeID,
            cachedAt: .now
        )
    }

    private func insertFeedAndDownload(
        feedURL: String,
        episodeID: String,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws -> String {
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Show \(episodeID)"))
        context.insert(PodcastCacheRecord(feedURL: feedURL, title: "Show \(episodeID)"))
        context.insert(
            EpisodeCacheRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                podcastTitle: "Show \(episodeID)",
                title: "Episode \(episodeID)",
                audioURL: "https://example.com/\(episodeID).mp3"
            )
        )
        _ = try insertCompletedDownload(
            episodeID: episodeID,
            podcastID: feedURL,
            sourceAudioURL: URL(string: "https://example.com/\(episodeID).mp3")!,
            fileStore: fileStore,
            context: context
        )

        return fileStore.relativePath(
            episodeID: episodeID,
            sourceAudioURL: URL(string: "https://example.com/\(episodeID).mp3")!
        )
    }

    @discardableResult
    private func insertCompletedDownload(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: URL,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws -> EpisodeDownloadRecord {
        let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceAudioURL)
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        let data = Data("downloaded \(episodeID)".utf8)
        try fileStore.prepareDownloadsDirectory()
        try data.write(to: fileURL, options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: sourceAudioURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        )
        context.insert(record)
        return record
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastDownloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCacheFixture(in directory: URL, fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: directory.appending(path: fileName), options: .atomic)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        return condition()
    }
}

private struct ChunkedEpisodeAudioDownloader: EpisodeAudioDownloading {
    let chunks: [Data]

    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
        }

        let expectedBytes = Int64(chunks.reduce(0) { $0 + $1.count })
        var receivedBytes: Int64 = 0
        for chunk in chunks {
            try Task.checkCancellation()
            try fileHandle.write(contentsOf: chunk)
            receivedBytes += Int64(chunk.count)
            await progress(receivedBytes, expectedBytes)
        }
    }
}

private struct HangingEpisodeAudioDownloader: EpisodeAudioDownloading {
    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        try Data("partial".utf8).write(to: temporaryURL, options: .atomic)
        await progress(7, 100)

        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }
}

private struct CompletedBytesHangingEpisodeAudioDownloader: EpisodeAudioDownloading {
    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let data = Data("complete".utf8)
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        try data.write(to: temporaryURL, options: .atomic)
        await progress(Int64(data.count), Int64(data.count))
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }
}

private final class ResumableGatedEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResumeContexts: [EpisodeDownloadResumeContext?] = []

    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        record(resume: resume)
        await onResponseMetadata(EpisodeDownloadResponseMetadata(
            entityTag: "resume-etag",
            lastModified: "Wed, 01 Jul 2026 00:00:00 GMT"
        ))

        if resume == nil {
            try Data("abc".utf8).write(to: temporaryURL, options: .atomic)
            await progress(3, 6)
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
        }

        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
        }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data("def".utf8))
        await progress(6, 6)
    }

    nonisolated func resumeContexts() -> [EpisodeDownloadResumeContext] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedResumeContexts.compactMap { $0 }
    }

    private nonisolated func record(resume: EpisodeDownloadResumeContext?) {
        lock.lock()
        recordedResumeContexts.append(resume)
        lock.unlock()
    }
}

private final class ResumeFailingOnceEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResumeOffsets: [Int64] = []

    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(EpisodeDownloadResponseMetadata(
            entityTag: "resume-etag",
            lastModified: nil
        ))

        if resume == nil {
            try Data("abc".utf8).write(to: temporaryURL, options: .atomic)
            await progress(3, 6)
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
        }

        let resumeAttempt = recordResumeAttempt(offset: resume?.offset ?? 0)
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
        }
        try fileHandle.seekToEnd()
        if resumeAttempt == 1 {
            try fileHandle.write(contentsOf: Data("d".utf8))
            await progress(4, 6)
            throw URLError(.notConnectedToInternet)
        }

        try fileHandle.write(contentsOf: Data("ef".utf8))
        await progress(6, 6)
    }

    nonisolated func resumeOffsets() -> [Int64] {
        lock.withLock { recordedResumeOffsets }
    }

    private nonisolated func recordResumeAttempt(offset: Int64) -> Int {
        lock.withLock {
            recordedResumeOffsets.append(offset)
            return recordedResumeOffsets.count
        }
    }
}

private final class HangingDownloadTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var expectedByteCount = 0

    static func configure(body: Data, expectedByteCount: Int) {
        lock.withLock {
            self.body = body
            self.expectedByteCount = expectedByteCount
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let fixture = Self.lock.withLock {
            (body: Self.body, expectedByteCount: Self.expectedByteCount)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": fixture.expectedByteCount.description]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
    }

    override func stopLoading() {
    }
}

private final class HangingAutoDeleteEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    func unload() async {
    }
}
