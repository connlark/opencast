import Foundation
import Observation
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

    @Test("record(for:) matches a linear scan through download, reload, and delete")
    func recordLookupMatchesLinearScan() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [Data("abc".utf8)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "index-equivalence")

        func expectLookupParity() {
            for episodeID in ["index-equivalence", "index-equivalence-missing"] {
                #expect(store.record(for: episodeID) === store.records.first { $0.episodeID == episodeID })
            }
        }

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)
        expectLookupParity()

        await store.load(modelContext: context)
        expectLookupParity()

        let record = try #require(store.record(for: episode.episodeID))
        store.deleteDownload(record, modelContext: context)
        expectLookupParity()
        #expect(store.record(for: episode.episodeID) == nil)
    }

    @Test("record(for:) registers Observation dependencies even with no record")
    func recordLookupRegistersObservationWithoutRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [Data("abc".utf8)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "observation-nil-lookup")

        // A body whose only store read is a nil record(for:) must still be
        // invalidated when the record appears — the ignored index alone
        // registers no dependency.
        try await confirmation("nil lookup invalidates when the record appears") { invalidated in
            withObservationTracking {
                #expect(store.record(for: episode.episodeID) == nil)
            } onChange: {
                invalidated()
            }
            store.startDownload(for: episode, modelContext: context)
            try await store.waitForDownload(episodeID: episode.episodeID)
        }

        let record = try #require(store.record(for: episode.episodeID))
        await confirmation("lookup invalidates when the record is deleted") { invalidated in
            withObservationTracking {
                _ = store.record(for: episode.episodeID)
            } onChange: {
                invalidated()
            }
            store.deleteDownload(record, modelContext: context)
        }
        #expect(store.record(for: episode.episodeID) == nil)
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

    @Test("ensureCompletedDownload throws instead of spinning when setup persistently fails")
    func ensureCompletedDownloadThrowsOnPersistentSetupFailure() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        // A base directory nested under a regular file makes every
        // prepareDownloadsDirectory call fail, so startDownload(for:) swallows
        // the setup error without ever creating a record.
        let blockerURL = temporaryDirectory.appending(path: "blocker")
        try Data("not a directory".utf8).write(to: blockerURL, options: .atomic)
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: blockerURL.appending(path: "base", directoryHint: .isDirectory)
        )
        let store = DownloadStore(fileStore: fileStore)
        let episode = makeEpisode(episodeID: "ensure-setup-failure")

        await #expect(throws: DownloadStore.CompletedDownloadError.self) {
            _ = try await store.ensureCompletedDownload(
                for: episode,
                modelContext: context,
                onWaitStarted: { try Task.checkCancellation() }
            )
        }
        #expect(store.record(for: episode.episodeID) == nil)
        #expect(store.lastErrorMessage(for: episode.episodeID) != nil)
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
    func reconcileMarksInterruptedAndMissingDownloads() async throws {
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

        await store.load(modelContext: context)

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

    @Test("Primary playback prefers a completed download")
    func primaryPlaybackPrefersCompletedDownload() async throws {
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
        await downloadStore.load(modelContext: context)

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

        defer { appModel.playback.unload() }
        // The fixture's RSS says 60 seconds. Local resume must survive past
        // that estimate while AVFoundation establishes the actual duration.
        try appModel.playback.load(downloadedEpisode, startPosition: 90)
        #expect(appModel.playback.position == 90)
        try appModel.playEpisode(episode, presentsNowPlaying: false, modelContext: context)
        #expect(appModel.playback.currentItemSourceIdentity?.assetURL == downloadedEpisode.audioURL)
    }

    @Test("Download completion switches the current episode even while backgrounded", arguments: [true, false])
    func downloadCompletionSwitchesCurrentEpisode(isSceneActive: Bool) async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(
            downloader: ChunkedEpisodeAudioDownloader(chunks: [Data("audio".utf8)]),
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: store,
            allowsAutomaticFeedRefresh: false
        )
        defer { appModel.playback.unload() }
        appModel.isSceneActive = isSceneActive
        let episode = makeEpisode(episodeID: "download-during-playback")
        let stream = try appModel.resolvedPlaybackEpisode(for: episode, source: .stream, modelContext: context)
        try appModel.playback.load(stream, startPosition: 27)
        appModel.playback.setRate(1.5)
        appModel.playback.setSleepTimer(mode: .endOfEpisode)

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        #expect(appModel.playback.currentItemSourceIdentity?.assetURL == store.localFileURL(for: record))
        #expect(appModel.playback.position == 27)
        #expect(appModel.playback.rate == 1.5)
        #expect(appModel.playback.sleepTimerMode == .endOfEpisode)
        #expect(!appModel.isNowPlayingPresented)
    }

    @Test("Another episode's completed download does not replace current playback")
    func downloadCompletionDoesNotReplaceAnotherEpisode() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(
            downloader: ChunkedEpisodeAudioDownloader(chunks: [Data("audio".utf8)]),
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        let appModel = OpenCastAppModel(downloads: store, allowsAutomaticFeedRefresh: false)
        defer { appModel.playback.unload() }
        let current = try appModel.resolvedPlaybackEpisode(
            for: makeEpisode(episodeID: "current"), source: .stream, modelContext: context
        )
        try appModel.playback.load(current, startPosition: 27)
        let other = makeEpisode(episodeID: "other")
        store.startDownload(for: other, modelContext: context)
        try await store.waitForDownload(episodeID: other.episodeID)

        #expect(appModel.playback.currentEpisode?.id == current.id)
        #expect(appModel.playback.currentItemSourceIdentity?.assetURL == current.audioURL)
    }

    @Test("Downloaded playback marks missing files before throwing")
    func downloadedPlaybackMarksMissingFilesBeforeThrowing() async throws {
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
        await downloadStore.load(modelContext: context)
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

    @Test("Unsubscribe removes only downloads for that feed, after the delete is confirmed")
    func unsubscribeRemovesOnlyDownloadsForThatFeed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloadStore,
            allowsAutomaticFeedRefresh: false
        )
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
        await appModel.library.load(modelContext: context)
        await downloadStore.load(modelContext: context)
        for feedURL in [removedFeedURL, keptFeedURL] {
            #expect(appModel.downloadSettings.setKeepLimitOverride(.two, forPodcastID: feedURL, modelContext: context))
            #expect(appModel.downloadSettings.setAutoDownloadsNewEpisodes(
                true,
                forPodcastID: feedURL,
                watermark: .distantPast,
                modelContext: context
            ))
        }

        let outcome = await appModel.unsubscribe(feedURL: removedFeedURL, modelContext: context)

        #expect(outcome == .removed(warning: nil))
        #expect(appModel.downloadSettings.autoDownloadPodcastIDs == [keptFeedURL])
        #expect(appModel.downloadSettings.keepLimitOverride(forPodcastID: removedFeedURL) == nil)
        #expect(appModel.downloadSettings.keepLimitOverride(forPodcastID: keptFeedURL) == .two)
        let reloadedSettings = DownloadSettingsStore()
        reloadedSettings.load(modelContext: context)
        #expect(reloadedSettings.autoDownloadPodcastIDs == [keptFeedURL])
        #expect(reloadedSettings.autoDownloadWatermark(forPodcastID: removedFeedURL) == nil)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).map(\.podcastID) == [keptFeedURL])
        #expect(fileStore.fileExists(relativePath: removedPath) == false)
        #expect(fileStore.fileExists(relativePath: keptPath))
        #expect(appModel.library.subscriptions.map(\.feedURL) == [keptFeedURL])
        #expect(appModel.library.episodes(forPodcastID: keptFeedURL).map(\.episodeID) == ["kept-episode"])
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
        await downloadStore.load(modelContext: context)
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
        await downloadStore.load(modelContext: context)
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

    @Test("Batch deletion commits record deletions before any file removal")
    func batchDeletionCommitsRecordsBeforeFileRemoval() async throws {
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
        await store.load(modelContext: context)

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

        let failedEpisodeID = failedRecord.episodeID
        let succeededEpisodeID = succeededRecord.episodeID
        store.deleteDownloads([failedRecord, succeededRecord], modelContext: context)

        // Record deletions commit in one save before any file is touched, so
        // the locked file can no longer strand unsaved deletions in the
        // shared context for an unrelated later save to pick up.
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        #expect(store.record(for: failedEpisodeID) == nil)
        #expect(store.record(for: succeededEpisodeID) == nil)
        // The undeletable file stays claimed-by-nothing until the next
        // launch's unclaimed-file sweep; the failure still surfaces.
        #expect(FileManager.default.fileExists(atPath: failedFileURL.path))
        #expect(fileStore.fileExists(relativePath: succeededRelativePath) == false)
        #expect(store.lastErrorMessage != nil)
    }

    @Test("Per-podcast storage cleanup removes completed downloads only")
    func perPodcastStorageCleanupKeepsActiveRecords() async throws {
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
        await downloadStore.load(modelContext: context)

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

        // This test is about a partial with bytes in it, so the stubbed body
        // being on disk is a precondition; a pause before the first byte has
        // its own tests below.
        store.startDownload(for: episode, modelContext: context)
        try #require(await waitUntil {
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

    @Test("Pausing before the first byte pauses at zero, survives reload, and resume starts over")
    func pausingBeforeTheFirstBytePausesAtZero() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloader = SilentThenCompletingEpisodeAudioDownloader()
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "pause-at-zero")

        store.startDownload(for: episode, modelContext: context)
        try #require(await waitUntil { downloader.resumeContexts().count == 1 })
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let paused = try #require(store.record(for: episode.episodeID))
        #expect(paused.state == .paused)
        #expect(paused.bytesReceived == 0)
        #expect(paused.errorMessage == nil)
        #expect(store.lastErrorMessage == nil)
        #expect(!FileManager.default.fileExists(
            atPath: fileStore.pausedPartialFileURL(episodeID: episode.episodeID).path
        ))

        let relaunchedStore = DownloadStore(downloader: downloader, fileStore: fileStore)
        await relaunchedStore.load(modelContext: context)
        #expect(relaunchedStore.record(for: episode.episodeID)?.state == .paused)

        relaunchedStore.resumeDownload(episodeID: episode.episodeID, modelContext: context)
        try await relaunchedStore.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(relaunchedStore.record(for: episode.episodeID))
        let relativePath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath)) == Data("abcdef".utf8))
        // Both attempts started from byte zero: there was nothing to resume.
        #expect(downloader.resumeContexts().allSatisfy { $0 == nil })
        #expect(downloader.resumeContexts().count == 2)
    }

    @Test("Pausing a real URLSession stream before its body arrives is a pause, not a failure")
    func pausingURLSessionStreamBeforeItsBodyPausesAtZero() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodylessDownloadTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = DownloadStore(
            downloader: URLSessionEpisodeAudioDownloader(session: session),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "url-session-pause-at-zero")

        // No wait before the pause: whether it lands before the response or
        // after it, no byte has arrived and the outcome has to be the same.
        store.startDownload(for: episode, modelContext: context)
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .paused)
        #expect(record.bytesReceived == 0)
        #expect(record.errorMessage == nil)
        #expect(!FileManager.default.fileExists(
            atPath: fileStore.pausedPartialFileURL(episodeID: episode.episodeID).path
        ))
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
        await relaunchedStore.load(modelContext: context)
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
    func reconcileAdoptsInterruptedPartialAndRejectsMissingPausedFile() async throws {
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
        context.insert(EpisodeDownloadRecord(
            episodeID: "paused-at-zero",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/paused-at-zero.mp3",
            state: .paused,
            bytesReceived: 0,
            bytesExpected: nil
        ))
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

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
        #expect(store.record(for: "paused-at-zero")?.state == .paused)
        #expect(store.record(for: "paused-at-zero")?.errorMessage == nil)
    }

    @Test("Reconcile deletes files no download record claims")
    func reconcileDeletesUnclaimedFiles() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let claimedAudioURL = URL(string: "https://example.com/claimed-episode.mp3")!
        _ = try insertCompletedDownload(
            episodeID: "claimed-episode",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: claimedAudioURL,
            fileStore: fileStore,
            context: context
        )
        context.insert(EpisodeDownloadRecord(
            episodeID: "claimed-paused",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/claimed-paused.mp3",
            state: .paused,
            bytesReceived: 14,
            bytesExpected: 100
        ))
        try Data("stable partial".utf8).write(
            to: fileStore.pausedPartialFileURL(episodeID: "claimed-paused"),
            options: .atomic
        )
        let orphanAudioURL = fileStore.fileURL(
            relativePath: "\(EpisodeDownloadFileStore.directoryName)/orphan-episode.mp3"
        )
        try Data("orphan audio".utf8).write(to: orphanAudioURL, options: .atomic)
        let orphanPartialURL = fileStore.temporaryFileURL(episodeID: "orphan-episode", token: "stranded")
        try Data("orphan partial".utf8).write(to: orphanPartialURL, options: .atomic)
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let claimedPath = fileStore.relativePath(
            episodeID: "claimed-episode",
            sourceAudioURL: claimedAudioURL
        )
        #expect(store.lastErrorMessage == nil)
        #expect(fileStore.fileExists(relativePath: claimedPath))
        #expect(FileManager.default.fileExists(
            atPath: fileStore.pausedPartialFileURL(episodeID: "claimed-paused").path
        ))
        #expect(!FileManager.default.fileExists(atPath: orphanAudioURL.path))
        #expect(!FileManager.default.fileExists(atPath: orphanPartialURL.path))
    }

    @Test("Reconcile preserves a paused partial when its size cannot be read")
    func reconcilePreservesUnreadablePausedPartial() async throws {
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
        await store.load(modelContext: context)
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

        await store.load(modelContext: context)
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
        await store.load(modelContext: context)

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
    func autoDeletePreferencePersistsAndControlsSweep() async throws {
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
        await downloadStore.load(modelContext: context)
        #expect(library.markEpisodePlayed(episode, modelContext: context))

        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)
        #expect(downloadStore.record(for: episode.episodeID) != nil)

        #expect(downloadStore.setAutoDeletesPlayedDownloads(true, modelContext: context))
        appModel.sweepPlayedDownloadsIfEnabled(modelContext: context)
        #expect(downloadStore.record(for: episode.episodeID) == nil)
        #expect(fileStore.fileExists(relativePath: relativePath) == false)

        let relaunchedStore = DownloadStore(fileStore: fileStore)
        await relaunchedStore.load(modelContext: context)
        #expect(relaunchedStore.autoDeletesPlayedDownloads)
    }

    @Test("Auto-delete keeps the currently playing download")
    func autoDeleteSkipsCurrentlyPlayingDownload() async throws {
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
        await downloadStore.load(modelContext: context)
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
        // The real BGTaskScheduler traps on a second same-identifier
        // registration in one host process, and suites run twice per
        // invocation — pass-arming tests must inject the fake scheduler.
        let appModel = OpenCastAppModel(
            library: library,
            downloads: downloadStore,
            adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession(
                scheduler: FakeAdFreePassContinuedTaskScheduler()
            )
        )
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
        await downloadStore.load(modelContext: context)
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
        await downloadStore.load(modelContext: context)
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

    @Test("Auto-delete sweeps a played download whose completed transcript matches it")
    func autoDeleteSweepsPlayedTranscriptMatchedDownload() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let episode = fixture.episode("scanned-swept", podcastID: KeepLimitFixture.showA)
        let record = try fixture.insert(episode.episodeID, podcastID: episode.podcastID, completedDay: 1)
        let downloadHash = record.sourceFileSHA256
        let downloadPath = try #require(record.localRelativePath)
        let transcriptPath = try writeCompletedTranscript(
            for: record,
            fileStore: transcriptFileStore,
            context: fixture.context
        )
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        #expect(fixture.library.markEpisodePlayed(episode, modelContext: fixture.context))
        #expect(fixture.downloads.setAutoDeletesPlayedDownloads(true, modelContext: fixture.context))
        #expect(!downloadHash.isEmpty)
        #expect(transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == downloadHash)
        try #require(transcriptions.record(for: episode.episodeID)?.state == .completed)

        fixture.appModel.sweepPlayedDownloadsIfEnabled(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: episode.episodeID) == nil)
        #expect(!fixture.fileStore.fileExists(relativePath: downloadPath))
        let transcript = try #require(transcriptions.record(for: episode.episodeID))
        #expect(transcript.state == .completed)
        #expect(transcript.sourceFileSHA256 == downloadHash)
        #expect(transcriptFileStore.documentExists(relativePath: transcriptPath))
    }

    @Test("Remove Played removes a played download whose completed transcript matches it")
    func removePlayedRemovesTranscriptMatchedDownload() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let episode = fixture.episode("scanned-removed", podcastID: KeepLimitFixture.showA)
        let record = try fixture.insert(episode.episodeID, podcastID: episode.podcastID, completedDay: 1)
        let downloadHash = record.sourceFileSHA256
        let downloadPath = try #require(record.localRelativePath)
        let transcriptPath = try writeCompletedTranscript(
            for: record,
            fileStore: transcriptFileStore,
            context: fixture.context
        )
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        #expect(fixture.library.markEpisodePlayed(episode, modelContext: fixture.context))
        #expect(!fixture.downloads.autoDeletesPlayedDownloads)
        #expect(!downloadHash.isEmpty)
        #expect(transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == downloadHash)
        try #require(transcriptions.record(for: episode.episodeID)?.state == .completed)

        fixture.appModel.deletePlayedDownloads(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: episode.episodeID) == nil)
        #expect(!fixture.fileStore.fileExists(relativePath: downloadPath))
        #expect(transcriptions.record(for: episode.episodeID)?.state == .completed)
        #expect(transcriptFileStore.documentExists(relativePath: transcriptPath))
    }

    @Test("Remove Played leaves a transcript-matched download that is the current episode")
    func removePlayedKeepsCurrentTranscriptMatchedDownload() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let episode = fixture.episode("scanned-current", podcastID: KeepLimitFixture.showA)
        let record = try fixture.insert(episode.episodeID, podcastID: episode.podcastID, completedDay: 1)
        try writeCompletedTranscript(for: record, fileStore: transcriptFileStore, context: fixture.context)
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        #expect(fixture.library.markEpisodePlayed(episode, modelContext: fixture.context))
        try fixture.appModel.playDownloadedEpisode(episode, downloadRecord: record, modelContext: fixture.context)
        defer { fixture.appModel.playback.unload() }
        #expect(fixture.library.progressRecord(for: episode.episodeID)?.isPlayed == true)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == episode.episodeID)
        try #require(transcriptions.record(for: episode.episodeID)?.state == .completed)

        fixture.appModel.deletePlayedDownloads(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .completed)

        fixture.appModel.playback.unload()
        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.library.progressRecord(for: episode.episodeID)?.isPlayed == true)
        fixture.appModel.deletePlayedDownloads(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: episode.episodeID) == nil)
    }

    @Test("A completed matching transcript with an open remote reference keeps the download")
    func autoDeleteKeepsTranscriptMatchedDownloadWithRemoteReference() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let jobs = RemoteTranscriptionJobStore(
            defaults: try #require(UserDefaults(suiteName: "SweepRemoteReference-\(UUID().uuidString)"))
        )
        let fixture = try await KeepLimitFixture.make(
            transcriptions: transcriptions,
            remoteTranscriptionJobStore: jobs
        )
        let episode = fixture.episode("scanned-remote", podcastID: KeepLimitFixture.showA)
        let record = try fixture.insert(episode.episodeID, podcastID: episode.podcastID, completedDay: 1)
        try writeCompletedTranscript(for: record, fileStore: transcriptFileStore, context: fixture.context)
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        #expect(fixture.library.markEpisodePlayed(episode, modelContext: fixture.context))
        #expect(fixture.downloads.setAutoDeletesPlayedDownloads(true, modelContext: fixture.context))
        // A remote run imports its transcript before it clears its reference.
        _ = jobs.reference(for: episode.episodeID)
        try #require(transcriptions.record(for: episode.episodeID)?.state == .completed)

        fixture.appModel.sweepPlayedDownloadsIfEnabled(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .completed)

        jobs.clearReference(for: episode.episodeID)
        fixture.appModel.sweepPlayedDownloadsIfEnabled(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: episode.episodeID) == nil)
    }

    @Test("A failed or interrupted transcript's hash doesn't keep a played download")
    func autoDeleteSweepsDownloadsWithStaleTranscriptHashes() async throws {
        let transcriptions = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let staleStates: [(episodeID: String, state: EpisodeTranscriptState)] = [
            ("stale-failed", .failed),
            ("stale-interrupted", .interrupted),
        ]
        for (day, stale) in staleStates.enumerated() {
            let record = try fixture.insert(stale.episodeID, podcastID: KeepLimitFixture.showA, completedDay: day)
            fixture.context.insert(EpisodeTranscriptRecord(
                episodeID: record.episodeID,
                podcastID: record.podcastID,
                sourceAudioURL: record.sourceAudioURL,
                sourceFileSHA256: record.sourceFileSHA256,
                state: stale.state
            ))
        }
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        for stale in staleStates {
            #expect(fixture.library.markEpisodePlayed(
                fixture.episode(stale.episodeID, podcastID: KeepLimitFixture.showA),
                modelContext: fixture.context
            ))
        }
        #expect(fixture.downloads.setAutoDeletesPlayedDownloads(true, modelContext: fixture.context))
        for stale in staleStates {
            let transcript = try #require(transcriptions.record(for: stale.episodeID))
            #expect(transcript.state == stale.state)
            #expect(!transcript.sourceFileSHA256.isEmpty)
            #expect(transcript.sourceFileSHA256 == fixture.downloads.record(for: stale.episodeID)?.sourceFileSHA256)
        }

        fixture.appModel.sweepPlayedDownloadsIfEnabled(modelContext: fixture.context)

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA).isEmpty)
    }

    @Test("The removable count matches what Remove Played removes")
    func removablePlayedDownloadCountMatchesRemovePlayed() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let scanned = try fixture.insert("count-a-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        let current = try fixture.insert("count-a-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        let played = try fixture.insert("count-b-1", podcastID: KeepLimitFixture.showB, completedDay: 1)
        try fixture.insert("count-b-2", podcastID: KeepLimitFixture.showB, completedDay: 2)
        for record in [scanned, current] {
            try writeCompletedTranscript(for: record, fileStore: transcriptFileStore, context: fixture.context)
        }
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        for record in [scanned, current, played] {
            #expect(fixture.library.markEpisodePlayed(
                fixture.episode(record.episodeID, podcastID: record.podcastID),
                modelContext: fixture.context
            ))
        }
        try fixture.appModel.playDownloadedEpisode(
            fixture.episode("count-a-2", podcastID: KeepLimitFixture.showA),
            downloadRecord: current,
            modelContext: fixture.context
        )
        defer { fixture.appModel.playback.unload() }
        #expect(fixture.library.progressRecord(for: "count-a-2")?.isPlayed == true)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "count-a-2")
        try #require(transcriptions.record(for: "count-a-1")?.state == .completed)
        try #require(transcriptions.record(for: "count-a-2")?.state == .completed)
        #expect(fixture.appModel.removablePlayedDownloadCount() == 2)

        fixture.appModel.deletePlayedDownloads(modelContext: fixture.context)

        #expect(fixture.appModel.removablePlayedDownloadCount() == 0)
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["count-a-2"])
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showB) == ["count-b-2"])
    }

    @Test("The removable count invalidates when protection changes")
    func removablePlayedDownloadCountInvalidatesWhenProtectionChanges() async throws {
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: HangingAutoDeleteEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let jobs = RemoteTranscriptionJobStore(
            defaults: try #require(UserDefaults(suiteName: "RemovableCount-\(UUID().uuidString)"))
        )
        let fixture = try await KeepLimitFixture.make(
            transcriptions: transcriptions,
            remoteTranscriptionJobStore: jobs
        )
        let appModel = fixture.appModel
        let episode = fixture.episode("count-protected", podcastID: KeepLimitFixture.showA)
        let record = try fixture.insert(episode.episodeID, podcastID: episode.podcastID, completedDay: 1)
        try await fixture.reload()
        #expect(fixture.library.markEpisodePlayed(episode, modelContext: fixture.context))
        #expect(appModel.removablePlayedDownloadCount() == 1)

        let localReservation = try transcriptions.reserveLocalWork(for: episode.episodeID).get()
        #expect(transcriptions.holdsWorkReservation(forEpisodeID: episode.episodeID))
        await confirmation("releasing a local reservation invalidates the count") { invalidated in
            withObservationTracking {
                #expect(appModel.removablePlayedDownloadCount() == 0)
            } onChange: {
                invalidated()
            }
            transcriptions.releaseLocalWork(localReservation)
        }
        #expect(appModel.removablePlayedDownloadCount() == 1)

        let remoteReservation = try transcriptions.reserveRemoteWork(for: episode.episodeID).get()
        #expect(transcriptions.holdsWorkReservation(forEpisodeID: episode.episodeID))
        await confirmation("releasing a remote reservation invalidates the count") { invalidated in
            withObservationTracking {
                #expect(appModel.removablePlayedDownloadCount() == 0)
            } onChange: {
                invalidated()
            }
            transcriptions.releaseRemoteWork(remoteReservation)
        }
        #expect(appModel.removablePlayedDownloadCount() == 1)

        _ = jobs.reference(for: episode.episodeID)
        await confirmation("clearing a remote job reference invalidates the count") { invalidated in
            withObservationTracking {
                #expect(appModel.removablePlayedDownloadCount() == 0)
            } onChange: {
                invalidated()
            }
            jobs.clearReference(for: episode.episodeID)
        }
        #expect(appModel.removablePlayedDownloadCount() == 1)

        let localFileURL = try #require(fixture.downloads.localFileURL(for: record))
        await confirmation("starting a transcription invalidates the count") { invalidated in
            withObservationTracking {
                #expect(appModel.removablePlayedDownloadCount() == 1)
            } onChange: {
                invalidated()
            }
            #expect(transcriptions.startTranscription(
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
                modelContext: fixture.context
            ))
        }
        #expect(appModel.removablePlayedDownloadCount() == 0)

        await confirmation("cancelling the transcription invalidates the count") { invalidated in
            withObservationTracking {
                #expect(appModel.removablePlayedDownloadCount() == 0)
            } onChange: {
                invalidated()
            }
            transcriptions.cancelTranscription(episodeID: episode.episodeID, modelContext: fixture.context)
            #expect(await waitUntil { !transcriptions.isActivelyTranscribing(episodeID: episode.episodeID) })
        }
        #expect(appModel.removablePlayedDownloadCount() == 1)
    }

    @Test("Keep Downloaded keeps a show's most recently completed downloads, by completion time")
    func keepLimitTrimsByCompletionTime() async throws {
        let fixture = try await KeepLimitFixture.make()
        // createdAt runs the other way, so only completedAt can order these.
        let showA = try (1...4).map { day in
            try fixture.insert("trim-a-\(day)", podcastID: KeepLimitFixture.showA, completedDay: day, createdDay: 10 - day)
        }
        for day in 1...2 {
            try fixture.insert("trim-b-\(day)", podcastID: KeepLimitFixture.showB, completedDay: day)
        }
        try await fixture.reload()
        let deletedPaths = try showA.prefix(2).map { try #require($0.localRelativePath) }

        #expect(fixture.appModel.setKeepLimitOverride(.two, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["trim-a-3", "trim-a-4"])
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showB) == ["trim-b-1", "trim-b-2"])
        #expect(deletedPaths.allSatisfy { !fixture.fileStore.fileExists(relativePath: $0) })
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).count == 4)
    }

    @Test("Downloads completed before completedAt existed rank by when they were first requested")
    func keepLimitFallsBackToCreatedAt() async throws {
        let fixture = try await KeepLimitFixture.make()
        for day in [1, 3, 5] {
            try fixture.insert("legacy-\(day)", podcastID: KeepLimitFixture.showA, completedDay: nil, createdDay: day)
        }
        try fixture.insert("modern-4", podcastID: KeepLimitFixture.showA, completedDay: 4)
        try await fixture.reload()

        #expect(fixture.appModel.setDefaultKeepLimit(.two, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["legacy-5", "modern-4"])
    }

    @Test("The playing download is never trimmed and keeps its place above the limit")
    func keepLimitKeepsPlayingDownload() async throws {
        let fixture = try await KeepLimitFixture.make()
        let oldest = try fixture.insert("playing-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        for day in 2...3 {
            try fixture.insert("playing-\(day)", podcastID: KeepLimitFixture.showA, completedDay: day)
        }
        try await fixture.reload()
        try fixture.appModel.playDownloadedEpisode(
            fixture.episode("playing-1", podcastID: KeepLimitFixture.showA),
            downloadRecord: oldest,
            modelContext: fixture.context
        )
        defer { fixture.appModel.playback.unload() }

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["playing-1", "playing-3"])
    }

    @Test("The trim keeps a download that is being transcribed")
    func keepLimitKeepsTranscribingDownload() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: HangingAutoDeleteEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let oldest = try fixture.insert("transcribing-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("transcribing-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try await fixture.reload()
        let localFileURL = try #require(fixture.downloads.localFileURL(for: oldest))
        transcriptions.startTranscription(
            fixture.episode("transcribing-1", podcastID: KeepLimitFixture.showA),
            downloadRecord: oldest,
            localFileURL: localFileURL,
            engine: .appleSpeech,
            modelIdentity: EpisodeTranscriptionModelIdentity(
                modelIdentifier: "apple-speech-transcriber.en_US",
                version: "iOS 26 test",
                treeSHA256: "installed-en-US"
            ),
            languageCode: "en-US",
            modelContext: fixture.context
        )
        #expect(await waitUntil { transcriptions.isActivelyTranscribing(episodeID: "transcribing-1") })

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["transcribing-1", "transcribing-2"])
        transcriptions.cancelTranscription(episodeID: "transcribing-1", modelContext: fixture.context)
    }

    @Test("The trim keeps a download queued for an ad-free pass")
    func keepLimitKeepsPassQueuedDownload() async throws {
        let fixture = try await KeepLimitFixture.make(downloader: HangingEpisodeAudioDownloader())
        try fixture.insert("pass-queued-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("pass-queued-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try await fixture.reload()
        let blocker = makeEpisode(episodeID: "pass-queued-blocker")
        let queued = fixture.episode("pass-queued-1", podcastID: KeepLimitFixture.showA)
        fixture.appModel.startAdFreePass(for: blocker, modelContext: fixture.context)
        #expect(await waitUntil { fixture.appModel.adFreePass.activeEpisodeID == blocker.episodeID })
        fixture.appModel.startAdFreePass(for: queued, modelContext: fixture.context)
        #expect(await waitUntil {
            if case .queued = fixture.appModel.adFreePass.queueStatus(for: queued.episodeID) {
                return true
            }
            return false
        })

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["pass-queued-1", "pass-queued-2"])
        fixture.appModel.adFreePass.reset()
        fixture.downloads.cancelDownload(episodeID: blocker.episodeID, modelContext: fixture.context)
    }

    @Test("The trim keeps a download a transcription request holds before transcribing starts")
    func keepLimitKeepsReservedDownload() async throws {
        let transcriptions = EpisodeTranscriptionStore()
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        try fixture.insert("reserved-local-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("reserved-remote-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try fixture.insert("reserved-newest-3", podcastID: KeepLimitFixture.showA, completedDay: 3)
        try await fixture.reload()
        let local = try transcriptions.workCoordinator.reserveLocal(episodeID: "reserved-local-1").get()
        let remote = try transcriptions.workCoordinator.reserveRemote(
            episodeID: "reserved-remote-2",
            activeLocalEpisodeID: nil
        ).get()
        #expect(!transcriptions.isActivelyTranscribing(episodeID: "reserved-local-1"))

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["reserved-local-1", "reserved-newest-3", "reserved-remote-2"])

        transcriptions.workCoordinator.releaseLocal(local)
        transcriptions.workCoordinator.releaseRemote(remote)
        fixture.appModel.trimDownloadsToKeepLimits(modelContext: fixture.context)
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["reserved-newest-3"])
    }

    @Test("The trim keeps a download whose remote transcription job may still ask for an exact copy")
    func keepLimitKeepsRemoteJobDownload() async throws {
        let defaults = try #require(UserDefaults(suiteName: "KeepLimitRemoteJob-\(UUID().uuidString)"))
        let jobs = RemoteTranscriptionJobStore(defaults: defaults)
        let fixture = try await KeepLimitFixture.make(remoteTranscriptionJobStore: jobs)
        try fixture.insert("remote-job-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("remote-job-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try await fixture.reload()
        _ = jobs.reference(for: "remote-job-1")

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["remote-job-1", "remote-job-2"])
    }

    @Test("The trim keeps an unplayed download whose completed transcript matches it")
    func keepLimitKeepsUnplayedTranscriptMatchedDownload() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let matched = try fixture.insert("matched-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("matched-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try writeCompletedTranscript(for: matched, fileStore: transcriptFileStore, context: fixture.context)
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        #expect(!matched.sourceFileSHA256.isEmpty)
        #expect(transcriptions.record(for: "matched-1")?.sourceFileSHA256 == matched.sourceFileSHA256)
        #expect(fixture.library.progressRecord(for: "matched-1")?.isPlayed != true)
        try #require(transcriptions.record(for: "matched-1")?.state == .completed)

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["matched-1", "matched-2"])
    }

    @Test("The trim removes a played download whose completed transcript matches it")
    func keepLimitRemovesPlayedTranscriptMatchedDownload() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let matched = try fixture.insert("matched-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("matched-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try writeCompletedTranscript(for: matched, fileStore: transcriptFileStore, context: fixture.context)
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        #expect(fixture.library.markEpisodePlayed(
            fixture.episode("matched-1", podcastID: KeepLimitFixture.showA),
            modelContext: fixture.context
        ))
        #expect(!matched.sourceFileSHA256.isEmpty)
        #expect(transcriptions.record(for: "matched-1")?.sourceFileSHA256 == matched.sourceFileSHA256)
        try #require(transcriptions.record(for: "matched-1")?.state == .completed)

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["matched-2"])
        #expect(transcriptions.record(for: "matched-1")?.state == .completed)
    }

    @Test("Only the trim keeps a transcript's audio, and only an unplayed episode's exact hash match")
    func transcriptAudioNeedsAnExactHashMatchAndOnlyTheTrimKeepsIt() async throws {
        func makeFixture() async throws -> KeepLimitFixture {
            let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
            let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
            let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
            try fixture.insert("boundary-no-transcript", podcastID: KeepLimitFixture.showA, completedDay: 1)
            let unhashed = try fixture.insert("boundary-unhashed", podcastID: KeepLimitFixture.showA, completedDay: 2)
            try writeCompletedTranscript(for: unhashed, fileStore: transcriptFileStore, context: fixture.context)
            unhashed.sourceFileSHA256 = ""
            let unequal = try fixture.insert("boundary-unequal", podcastID: KeepLimitFixture.showA, completedDay: 3)
            try writeCompletedTranscript(
                for: unequal,
                sourceFileSHA256: OpenCastSHA256.hash(Data("other bytes".utf8)),
                fileStore: transcriptFileStore,
                context: fixture.context
            )
            let matched = try fixture.insert("boundary-matched", podcastID: KeepLimitFixture.showA, completedDay: 4)
            try writeCompletedTranscript(for: matched, fileStore: transcriptFileStore, context: fixture.context)
            try fixture.insert("boundary-newest", podcastID: KeepLimitFixture.showA, completedDay: 5)
            try await fixture.reload()
            transcriptions.load(modelContext: fixture.context)
            for episodeID in ["boundary-unhashed", "boundary-unequal", "boundary-matched"] {
                #expect(transcriptions.record(for: episodeID)?.state == .completed)
                #expect(transcriptions.record(for: episodeID)?.sourceFileSHA256.isEmpty == false)
            }
            #expect(fixture.downloads.record(for: "boundary-no-transcript")?.sourceFileSHA256.isEmpty == false)
            #expect(fixture.downloads.record(for: "boundary-unhashed")?.sourceFileSHA256 == "")
            #expect(transcriptions.record(for: "boundary-unequal")?.sourceFileSHA256
                != fixture.downloads.record(for: "boundary-unequal")?.sourceFileSHA256)
            #expect(transcriptions.record(for: "boundary-matched")?.sourceFileSHA256
                == fixture.downloads.record(for: "boundary-matched")?.sourceFileSHA256)
            return fixture
        }

        let sweepFixture = try await makeFixture()
        for episodeID in ["boundary-no-transcript", "boundary-unhashed", "boundary-unequal"] {
            #expect(sweepFixture.library.markEpisodePlayed(
                sweepFixture.episode(episodeID, podcastID: KeepLimitFixture.showA),
                modelContext: sweepFixture.context
            ))
        }
        #expect(sweepFixture.downloads.setAutoDeletesPlayedDownloads(true, modelContext: sweepFixture.context))

        sweepFixture.appModel.sweepPlayedDownloadsIfEnabled(modelContext: sweepFixture.context)

        #expect(sweepFixture.episodeIDs(for: KeepLimitFixture.showA) == ["boundary-matched", "boundary-newest"])

        let trimFixture = try await makeFixture()

        #expect(trimFixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: trimFixture.context))

        #expect(trimFixture.episodeIDs(for: KeepLimitFixture.showA) == ["boundary-matched", "boundary-newest"])
    }

    @Test("The launch sweep and trim remove a played scanned download above its show's limit once")
    func launchSweepThenTrimRemovesPlayedTranscriptMatchedDownloadOnce() async throws {
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let fixture = try await KeepLimitFixture.make(transcriptions: transcriptions)
        let scanned = try fixture.insert("launch-a-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("launch-a-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        let otherShowScanned = try fixture.insert("launch-b-1", podcastID: KeepLimitFixture.showB, completedDay: 1)
        try fixture.insert("launch-b-2", podcastID: KeepLimitFixture.showB, completedDay: 2)
        for record in [scanned, otherShowScanned] {
            try writeCompletedTranscript(for: record, fileStore: transcriptFileStore, context: fixture.context)
        }
        let scannedPath = try #require(scanned.localRelativePath)
        try await fixture.reload()
        transcriptions.load(modelContext: fixture.context)
        // Saved without the app model, so nothing has trimmed show A yet.
        #expect(fixture.appModel.downloadSettings.setKeepLimitOverride(
            .one,
            forPodcastID: KeepLimitFixture.showA,
            modelContext: fixture.context
        ))
        #expect(fixture.library.markEpisodePlayed(
            fixture.episode("launch-a-1", podcastID: KeepLimitFixture.showA),
            modelContext: fixture.context
        ))
        #expect(fixture.downloads.setAutoDeletesPlayedDownloads(true, modelContext: fixture.context))
        try #require(transcriptions.record(for: "launch-a-1")?.state == .completed)
        try #require(transcriptions.record(for: "launch-b-1")?.state == .completed)

        fixture.appModel.sweepPlayedDownloadsIfEnabled(modelContext: fixture.context)

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["launch-a-2"])

        fixture.appModel.trimDownloadsToKeepLimits(modelContext: fixture.context)

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["launch-a-2"])
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showB) == ["launch-b-1", "launch-b-2"])
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).count == 3)
        #expect(!fixture.fileStore.fileExists(relativePath: scannedPath))
        #expect(transcriptions.record(for: "launch-a-1")?.state == .completed)
    }

    @Test("Played state doesn't decide what the trim keeps")
    func keepLimitIgnoresPlayedState() async throws {
        let fixture = try await KeepLimitFixture.make()
        try fixture.insert("played-1", podcastID: KeepLimitFixture.showA, completedDay: 1)
        try fixture.insert("played-2", podcastID: KeepLimitFixture.showA, completedDay: 2)
        try await fixture.reload()
        #expect(fixture.library.markEpisodePlayed(
            fixture.episode("played-2", podcastID: KeepLimitFixture.showA),
            modelContext: fixture.context
        ))

        #expect(fixture.appModel.setKeepLimitOverride(.one, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["played-2"])
    }

    @Test("No Limit never trims, at launch or on activation")
    func noLimitNeverTrims() async throws {
        let fixture = try await KeepLimitFixture.make()
        for day in 1...12 {
            try fixture.insert("unlimited-\(day)", podcastID: KeepLimitFixture.showA, completedDay: day)
        }
        try await fixture.reload()

        fixture.appModel.trimDownloadsToKeepLimits(modelContext: fixture.context)

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA).count == 12)
    }

    @Test("Changing the default trims every show without its own limit; a show's own limit wins")
    func defaultLimitTrimsAllShowsAndOverrideWins() async throws {
        let fixture = try await KeepLimitFixture.make()
        for day in 1...4 {
            try fixture.insert("default-a-\(day)", podcastID: KeepLimitFixture.showA, completedDay: day)
            try fixture.insert("default-b-\(day)", podcastID: KeepLimitFixture.showB, completedDay: day)
        }
        try await fixture.reload()
        #expect(fixture.appModel.downloadSettings.setKeepLimitOverride(
            .three,
            forPodcastID: KeepLimitFixture.showA,
            modelContext: fixture.context
        ))

        #expect(fixture.appModel.setDefaultKeepLimit(.one, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["default-a-2", "default-a-3", "default-a-4"])
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showB) == ["default-b-4"])
    }

    @Test("Changing a show's limit trims only that show")
    func showLimitTrimsOnlyThatShow() async throws {
        let fixture = try await KeepLimitFixture.make()
        for day in 1...3 {
            try fixture.insert("scoped-a-\(day)", podcastID: KeepLimitFixture.showA, completedDay: day)
            try fixture.insert("scoped-b-\(day)", podcastID: KeepLimitFixture.showB, completedDay: day)
        }
        try await fixture.reload()
        // Saved without the app model, so nothing has trimmed show B yet.
        #expect(fixture.appModel.downloadSettings.setDefaultKeepLimit(.one, modelContext: fixture.context))

        #expect(fixture.appModel.setKeepLimitOverride(.two, forPodcastID: KeepLimitFixture.showA, modelContext: fixture.context))

        #expect(fixture.episodeIDs(for: KeepLimitFixture.showA) == ["scoped-a-2", "scoped-a-3"])
        #expect(fixture.episodeIDs(for: KeepLimitFixture.showB).count == 3)
    }

    @Test("A finished download trims its show, outside the completion commit, and keeps itself")
    func completionTrimsShow() async throws {
        let fixture = try await KeepLimitFixture.make(
            downloader: ChunkedEpisodeAudioDownloader(chunks: [Data("fresh".utf8)])
        )
        let episode = makeEpisode(episodeID: "completion-new")
        try fixture.insert("completion-old", podcastID: episode.podcastID, completedDay: 1)
        try await fixture.reload()
        #expect(fixture.appModel.downloadSettings.setKeepLimitOverride(
            .one,
            forPodcastID: episode.podcastID,
            modelContext: fixture.context
        ))

        fixture.downloads.startDownload(for: episode, modelContext: fixture.context)
        try await fixture.downloads.waitForDownload(episodeID: episode.episodeID)

        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .completed)
        #expect(fixture.downloads.record(for: episode.episodeID)?.completedAt != nil)
        #expect(await waitUntil { fixture.downloads.record(for: "completion-old") == nil })
        #expect(fixture.episodeIDs(for: episode.podcastID) == ["completion-new"])
    }

    @Test("onDownloadCompleted fires once per finished download, never for reloads or deletes")
    func completionHookFiresOnce() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let store = DownloadStore(
            downloader: ChunkedEpisodeAudioDownloader(chunks: [Data("abc".utf8), Data("def".utf8)]),
            fileStore: fileStore
        )
        var completedEpisodeIDs: [String] = []
        store.onDownloadCompleted = { record, _ in
            completedEpisodeIDs.append(record.episodeID)
        }
        let episode = makeEpisode(episodeID: "hook-once")

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)
        await store.load(modelContext: context)
        let record = try #require(store.record(for: episode.episodeID))
        store.deleteDownload(record, modelContext: context)

        #expect(completedEpisodeIDs == [episode.episodeID])
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
        await store.load(modelContext: context)

        // The record predates hash persistence, so the identity is honestly
        // unavailable until something recomputes it from the file.
        #expect(store.completedSourceIdentity(for: "identity-legacy") == nil)
    }

    @Test("An extension-less enclosure completes under the extension its bytes prove")
    func extensionlessEnclosureCompletesUnderSniffedExtension() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let audio = EpisodeDownloadAudioFixtures.taggedMP3
        let downloader = ChunkedEpisodeAudioDownloader(chunks: [audio.prefix(5), audio.dropFirst(5)])
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "extensionless", audioURL: Self.extensionlessAudioURL)

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        let relativePath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(relativePath.hasSuffix(".mp3"))
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath)) == audio)
        #expect(try downloadsDirectoryFileNames(fileStore) == ["extensionless.mp3"])
    }

    @Test("An unsniffable extension-less enclosure takes its Content-Disposition extension")
    func unsniffableEnclosureTakesSuggestedFilenameExtension() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloader = ChunkedEpisodeAudioDownloader(
            chunks: [Data("no recognizable header".utf8)],
            metadata: EpisodeDownloadResponseMetadata(
                entityTag: nil,
                lastModified: nil,
                suggestedFilename: "a.m4a",
                mimeType: "application/octet-stream"
            )
        )
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "extensionless-named", audioURL: Self.extensionlessAudioURL)

        store.startDownload(for: episode, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .completed)
        #expect(record.localRelativePath?.hasSuffix(".m4a") == true)
        #expect(try downloadsDirectoryFileNames(fileStore) == ["extensionless-named.m4a"])
    }

    @Test("A pause after an extension-less enclosure's final bytes still settles the extension")
    func pauseAfterFinalBytesSettlesExtension() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let audio = EpisodeDownloadAudioFixtures.taggedMP3
        let store = DownloadStore(
            downloader: CompletedBytesHangingEpisodeAudioDownloader(data: audio),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "extensionless-paused-complete", audioURL: Self.extensionlessAudioURL)

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .downloading
                && store.byteProgress(for: episode.episodeID)?.bytesReceived == Int64(audio.count)
        })
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .completed)
        #expect(record.localRelativePath?.hasSuffix(".mp3") == true)
        #expect(try downloadsDirectoryFileNames(fileStore) == ["extensionless-paused-complete.mp3"])
    }

    @Test("A pause after an unsniffable enclosure's final bytes settles from the response hints")
    func pauseAfterFinalBytesSettlesFromResponseHints() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let audio = Data("no recognizable header".utf8)
        let store = DownloadStore(
            downloader: CompletedBytesHangingEpisodeAudioDownloader(
                data: audio,
                metadata: EpisodeDownloadResponseMetadata(
                    entityTag: nil,
                    lastModified: nil,
                    suggestedFilename: nil,
                    mimeType: "audio/x-m4a"
                )
            ),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "extensionless-paused-hinted", audioURL: Self.extensionlessAudioURL)

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .downloading
                && store.byteProgress(for: episode.episodeID)?.bytesReceived == Int64(audio.count)
        })
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        #expect(record.state == .completed)
        #expect(record.localRelativePath?.hasSuffix(".m4a") == true)
        #expect(try downloadsDirectoryFileNames(fileStore) == ["extensionless-paused-hinted.m4a"])
    }

    @Test("Pausing and resuming an extension-less enclosure leaves one file named for its bytes")
    func pauseResumeExtensionlessEnclosureSettlesOnce() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let firstChunk = EpisodeDownloadAudioFixtures.taggedMP3
        let downloader = ResumableGatedEpisodeAudioDownloader(firstChunk: firstChunk)
        let store = DownloadStore(downloader: downloader, fileStore: fileStore)
        let episode = makeEpisode(episodeID: "extensionless-resume", audioURL: Self.extensionlessAudioURL)

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil {
            store.byteProgress(for: episode.episodeID)?.bytesReceived == Int64(firstChunk.count)
        })
        store.pauseDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)
        try #require(store.record(for: episode.episodeID)?.state == .paused)

        store.resumeDownload(episodeID: episode.episodeID, modelContext: context)
        try await store.waitForDownload(episodeID: episode.episodeID)

        let record = try #require(store.record(for: episode.episodeID))
        let relativePath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(relativePath.hasSuffix(".mp3"))
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath)) == firstChunk + Data("def".utf8))
        #expect(try downloadsDirectoryFileNames(fileStore) == ["extensionless-resume.mp3"])
    }

    @Test("Launch reconciliation renames a completed download whose bytes classify")
    func reconcileRenamesClassifiableCompletedDownload() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let audio = EpisodeDownloadAudioFixtures.taggedMP3
        let inserted = try insertCompletedDownload(
            episodeID: "repair-classified",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: try #require(URL(string: Self.extensionlessAudioURL)),
            data: audio,
            fileStore: fileStore,
            context: context
        )
        inserted.sourceFileSHA256 = OpenCastSHA256.hash(audio)
        let storedPath = try #require(inserted.localRelativePath)
        try #require(storedPath.hasSuffix(".audio"))
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let record = try #require(store.record(for: "repair-classified"))
        let repairedPath = try #require(record.localRelativePath)
        #expect(store.lastErrorMessage == nil)
        #expect(record.state == .completed)
        #expect(repairedPath.hasSuffix(".mp3"))
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: repairedPath)) == audio)
        #expect(!fileStore.fileExists(relativePath: storedPath))
        #expect(record.sourceFileSHA256 == OpenCastSHA256.hash(audio))
        #expect(store.completedSourceIdentity(for: "repair-classified") != nil)
    }

    @Test("Launch reconciliation leaves an unclassifiable completed download alone")
    func reconcileLeavesUnclassifiableCompletedDownload() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let inserted = try insertCompletedDownload(
            episodeID: "repair-unclassified",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: try #require(URL(string: Self.extensionlessAudioURL)),
            fileStore: fileStore,
            context: context
        )
        let storedPath = try #require(inserted.localRelativePath)
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let record = try #require(store.record(for: "repair-unclassified"))
        #expect(store.lastErrorMessage == nil)
        #expect(record.state == .completed)
        #expect(record.localRelativePath == storedPath)
        #expect(fileStore.fileExists(relativePath: storedPath))
    }

    @Test("Launch reconciliation re-points a completed record at its renamed sibling")
    func reconcileRepointsCompletedRecordAtRenamedSibling() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let audio = EpisodeDownloadAudioFixtures.taggedMP3
        let inserted = try insertCompletedDownload(
            episodeID: "repair-sibling",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: try #require(URL(string: Self.extensionlessAudioURL)),
            data: audio,
            fileStore: fileStore,
            context: context
        )
        inserted.sourceFileSHA256 = OpenCastSHA256.hash(audio)
        let storedPath = try #require(inserted.localRelativePath)
        // The launch repair renamed the file and died before saving the record.
        let siblingURL = fileStore.downloadsDirectory.appending(path: "repair-sibling.mp3")
        try FileManager.default.moveItem(at: fileStore.fileURL(relativePath: storedPath), to: siblingURL)
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let record = try #require(store.record(for: "repair-sibling"))
        let repairedPath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(repairedPath.hasSuffix(".mp3"))
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: repairedPath)) == audio)
        #expect(store.completedSourceIdentity(for: "repair-sibling")?.sha256 == OpenCastSHA256.hash(audio))
    }

    @Test("Launch reconciliation does not adopt an equal-size sibling whose bytes miss the recorded hash")
    func reconcileIgnoresSiblingWithOtherBytes() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let audio = EpisodeDownloadAudioFixtures.taggedMP3
        let inserted = try insertCompletedDownload(
            episodeID: "repair-other-bytes",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: try #require(URL(string: Self.extensionlessAudioURL)),
            data: audio,
            fileStore: fileStore,
            context: context
        )
        inserted.sourceFileSHA256 = OpenCastSHA256.hash(audio)
        let storedPath = try #require(inserted.localRelativePath)
        try FileManager.default.removeItem(at: fileStore.fileURL(relativePath: storedPath))
        // An earlier download kept under the same stem, with the same length.
        var staleAudio = audio
        staleAudio[staleAudio.endIndex - 1] ^= 0xFF
        let siblingURL = fileStore.downloadsDirectory.appending(path: "repair-other-bytes.mp3")
        try staleAudio.write(to: siblingURL, options: .atomic)
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let record = try #require(store.record(for: "repair-other-bytes"))
        #expect(record.state == .missing)
        #expect(record.localRelativePath == storedPath)
        #expect(try Data(contentsOf: siblingURL) == staleAudio)
    }

    @Test("A download that completes while launch reconciliation probes keeps its record")
    func reconcileSkipsVerdictsForReplacedRecords() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let staleAudio = EpisodeDownloadAudioFixtures.taggedMP3 + Data("stale".utf8)
        let inserted = try insertCompletedDownload(
            episodeID: "replaced-during-probe",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: try #require(URL(string: Self.extensionlessAudioURL)),
            data: staleAudio,
            fileStore: fileStore,
            context: context
        )
        inserted.sourceFileSHA256 = OpenCastSHA256.hash(staleAudio)
        let storedPath = try #require(inserted.localRelativePath)
        try FileManager.default.removeItem(at: fileStore.fileURL(relativePath: storedPath))
        // An equal-size sibling with other bytes: the probe's verdict is
        // `.markMissing`.
        var siblingAudio = staleAudio
        siblingAudio[siblingAudio.endIndex - 1] ^= 0xFF
        try siblingAudio.write(
            to: fileStore.downloadsDirectory.appending(path: "replaced-during-probe.mp3"),
            options: .atomic
        )
        try context.save()

        let freshAudio = EpisodeDownloadAudioFixtures.taggedMP3 + Data("fresh download".utf8)
        let store = DownloadStore(
            downloader: ChunkedEpisodeAudioDownloader(chunks: [freshAudio]),
            fileStore: fileStore
        )
        let episode = makeEpisode(episodeID: "replaced-during-probe", audioURL: Self.extensionlessAudioURL)
        store.afterReconcileProbesForTesting = {
            store.startDownload(for: episode, modelContext: context)
            try? await store.waitForDownload(episodeID: episode.episodeID)
        }
        await store.load(modelContext: context)

        let record = try #require(store.record(for: episode.episodeID))
        let relativePath = try #require(record.localRelativePath)
        #expect(record.state == .completed)
        #expect(record.sourceFileSHA256 == OpenCastSHA256.hash(freshAudio))
        #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath)) == freshAudio)
    }

    @Test("Launch reconciliation never repairs two colliding stems onto one name")
    func reconcileReservesRepairTargetsAcrossCollidingStems() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        // "collide x" and "collide-x" share the stem "collide-x"; the two
        // enclosures differ only in their non-audio extensions.
        let audioByEpisodeID = [
            "collide x": EpisodeDownloadAudioFixtures.taggedMP3 + Data("first".utf8),
            "collide-x": EpisodeDownloadAudioFixtures.taggedMP3 + Data("second".utf8),
        ]
        let sourceURLByEpisodeID = [
            "collide x": try #require(URL(string: "https://example.com/get/first")),
            "collide-x": try #require(URL(string: "https://example.com/get/second.php")),
        ]
        for (episodeID, audio) in audioByEpisodeID {
            _ = try insertCompletedDownload(
                episodeID: episodeID,
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: try #require(sourceURLByEpisodeID[episodeID]),
                data: audio,
                fileStore: fileStore,
                context: context
            )
        }
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let records = try audioByEpisodeID.keys.map { try #require(store.record(for: $0)) }
        let paths = records.compactMap(\.localRelativePath)
        #expect(Set(paths).count == 2)
        #expect(paths.count { $0.hasSuffix(".mp3") } == 1)
        for record in records {
            let relativePath = try #require(record.localRelativePath)
            #expect(record.state == .completed)
            #expect(try Data(contentsOf: fileStore.fileURL(relativePath: relativePath))
                == audioByEpisodeID[record.episodeID])
        }
    }

    @Test("Launch reconciliation does not adopt a sibling of the wrong size")
    func reconcileIgnoresWrongSizeSibling() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let inserted = try insertCompletedDownload(
            episodeID: "repair-wrong-size",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: try #require(URL(string: Self.extensionlessAudioURL)),
            data: Data("ID3 our audio".utf8),
            fileStore: fileStore,
            context: context
        )
        let storedPath = try #require(inserted.localRelativePath)
        try FileManager.default.removeItem(at: fileStore.fileURL(relativePath: storedPath))
        let foreignAudio = Data("ID3 somebody else's longer audio".utf8)
        let siblingURL = fileStore.downloadsDirectory.appending(path: "repair-wrong-size.mp3")
        try foreignAudio.write(to: siblingURL, options: .atomic)
        try context.save()

        let store = DownloadStore(fileStore: fileStore)
        await store.load(modelContext: context)

        let record = try #require(store.record(for: "repair-wrong-size"))
        #expect(record.state == .missing)
        #expect(record.localRelativePath == storedPath)
        #expect(try Data(contentsOf: siblingURL) == foreignAudio)
    }

    private static let extensionlessAudioURL = "https://example.com/get/abc?file=track.mp3"

    private func downloadsDirectoryFileNames(_ fileStore: EpisodeDownloadFileStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: fileStore.downloadsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        makeEpisode(episodeID: episodeID, audioURL: "https://example.com/\(episodeID).mp3")
    }

    private func makeEpisode(episodeID: String, audioURL: String?) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            duration: 120,
            audioURL: audioURL,
            artworkURL: "https://example.com/art.jpg",
            guid: episodeID
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
        data: Data? = nil,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws -> EpisodeDownloadRecord {
        let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceAudioURL)
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        let data = data ?? Data("downloaded \(episodeID)".utf8)
        try fileStore.prepareDownloadsDirectory()
        try data.write(to: fileURL, options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: sourceAudioURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count),
            completedAt: .now
        )
        record.sourceFileSHA256 = OpenCastSHA256.hash(data)
        context.insert(record)
        return record
    }

    /// A completed transcript of the download's bytes (or of the bytes
    /// `sourceFileSHA256` names), with its document on disk so the
    /// transcription store's `load` keeps it completed.
    @discardableResult
    private func writeCompletedTranscript(
        for record: EpisodeDownloadRecord,
        sourceFileSHA256: String? = nil,
        fileStore: EpisodeTranscriptFileStore,
        context: ModelContext
    ) throws -> String {
        let text = "Welcome back to the show."
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: record.episodeID,
            podcastID: record.podcastID,
            sourceAudioURL: record.sourceAudioURL,
            sourceFileByteCount: record.bytesReceived,
            sourceFileSHA256: sourceFileSHA256 ?? record.sourceFileSHA256,
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: 120,
            checkpoints: [],
            segments: [
                OpenCastTranscriptSegment(
                    id: 0,
                    start: 0,
                    end: 5,
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
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: document.episodeID, fingerprint: fingerprint)
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            sourceAudioURL: document.sourceAudioURL,
            sourceFileByteCount: document.sourceFileByteCount,
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256,
            languageCode: document.languageCode,
            state: .completed,
            audioDuration: document.audioDuration,
            completedDuration: document.audioDuration,
            transcriptRelativePath: relativePath,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        ))
        try context.save()
        return relativePath
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
}

private struct ChunkedEpisodeAudioDownloader: EpisodeAudioDownloading {
    let chunks: [Data]
    var metadata = EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil)

    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(metadata)
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
    var data = Data("complete".utf8)
    var metadata = EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil)

    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(metadata)
        try data.write(to: temporaryURL, options: .atomic)
        await progress(Int64(data.count), Int64(data.count))
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }
}

nonisolated private final class ResumableGatedEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private let firstChunk: Data
    private var recordedResumeContexts: [EpisodeDownloadResumeContext?] = []

    init(firstChunk: Data = Data("abc".utf8)) {
        self.firstChunk = firstChunk
    }

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

        let secondChunk = Data("def".utf8)
        let totalByteCount = Int64(firstChunk.count + secondChunk.count)
        if resume == nil {
            try firstChunk.write(to: temporaryURL, options: .atomic)
            await progress(Int64(firstChunk.count), totalByteCount)
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
        try fileHandle.write(contentsOf: secondChunk)
        await progress(totalByteCount, totalByteCount)
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

/// First attempt: parks without a response, a file or a byte until it is
/// cancelled. Later attempts write the whole body and return.
nonisolated private final class SilentThenCompletingEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResumeContexts: [EpisodeDownloadResumeContext?] = []

    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let attempt = lock.withLock {
            recordedResumeContexts.append(resume)
            return recordedResumeContexts.count
        }
        if attempt == 1 {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
        }

        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        try Data("abcdef".utf8).write(to: temporaryURL, options: .atomic)
        await progress(6, 6)
    }

    nonisolated func resumeContexts() -> [EpisodeDownloadResumeContext?] {
        lock.withLock { recordedResumeContexts }
    }
}

nonisolated private final class ResumeFailingOnceEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
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

/// Answers with headers and then never sends a body byte. It keeps no shared
/// state, so it cannot interfere with the configurable stub above.
private final class BodylessDownloadTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4096"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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

/// Completed downloads for two shows with chosen completion and request
/// days, behind an app model whose cleanup coordinator runs the trim.
@MainActor
private final class KeepLimitFixture {
    static let showA = "https://example.com/feed.xml"
    static let showB = "https://example.com/other-feed.xml"
    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    let context: ModelContext
    let fileStore: EpisodeDownloadFileStore
    let downloads: DownloadStore
    let library: LibraryStore
    let appModel: OpenCastAppModel

    private init(
        context: ModelContext,
        fileStore: EpisodeDownloadFileStore,
        downloads: DownloadStore,
        library: LibraryStore,
        appModel: OpenCastAppModel
    ) {
        self.context = context
        self.fileStore = fileStore
        self.downloads = downloads
        self.library = library
        self.appModel = appModel
    }

    static func make(
        downloader: any EpisodeAudioDownloading = URLSessionEpisodeAudioDownloader(),
        transcriptions: EpisodeTranscriptionStore = EpisodeTranscriptionStore(),
        remoteTranscriptionJobStore: RemoteTranscriptionJobStore? = nil
    ) async throws -> KeepLimitFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastKeepLimitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let downloads = DownloadStore(downloader: downloader, fileStore: fileStore)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        // Pass-arming tests need the fake scheduler: the real one traps on a
        // second same-identifier registration in one host process.
        let appModel = OpenCastAppModel(
            library: library,
            downloads: downloads,
            transcriptions: transcriptions,
            remoteTranscriptionJobStore: remoteTranscriptionJobStore ?? RemoteTranscriptionJobStore(
                defaults: UserDefaults(suiteName: "KeepLimitFixture-\(UUID().uuidString)")!
            ),
            adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession(
                scheduler: FakeAdFreePassContinuedTaskScheduler()
            )
        )
        return KeepLimitFixture(
            context: ModelContext(container),
            fileStore: fileStore,
            downloads: downloads,
            library: library,
            appModel: appModel
        )
    }

    /// A nil `completedDay` stands for a record completed before the field
    /// existed.
    @discardableResult
    func insert(
        _ episodeID: String,
        podcastID: String,
        completedDay: Int?,
        createdDay: Int = 0
    ) throws -> EpisodeDownloadRecord {
        let sourceAudioURL = URL(string: "https://example.com/\(episodeID).mp3")!
        let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceAudioURL)
        let data = Data("downloaded \(episodeID)".utf8)
        try fileStore.prepareDownloadsDirectory()
        try data.write(to: fileStore.fileURL(relativePath: relativePath), options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: sourceAudioURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count),
            completedAt: completedDay.map(Self.day),
            createdAt: Self.day(createdDay)
        )
        record.sourceFileSHA256 = OpenCastSHA256.hash(data)
        context.insert(record)
        return record
    }

    func reload() async throws {
        try context.save()
        await downloads.load(modelContext: context)
    }

    func episode(_ episodeID: String, podcastID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            podcastID: podcastID,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    func episodeIDs(for podcastID: String) -> [String] {
        downloads.records
            .filter { $0.podcastID == podcastID && $0.state == .completed }
            .map(\.episodeID)
            .sorted()
    }

    private static func day(_ day: Int) -> Date {
        base.addingTimeInterval(Double(day) * 86_400)
    }
}
