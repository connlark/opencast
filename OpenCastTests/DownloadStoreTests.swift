import Foundation
import OpenCastCore
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
        await store.waitForDownload(episodeID: episode.episodeID)

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

    @Test("Cancel removes the download record and partial file")
    func cancelRemovesRecordAndPartialFile() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let store = DownloadStore(downloader: HangingEpisodeAudioDownloader(), fileStore: fileStore)
        let episode = makeEpisode(episodeID: "download-cancel")

        store.startDownload(for: episode, modelContext: context)
        #expect(await waitUntil { store.record(for: episode.episodeID)?.bytesReceived == 7 })

        store.cancelDownload(episodeID: episode.episodeID, modelContext: context)

        #expect(store.record(for: episode.episodeID) == nil)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        let relativePath = fileStore.relativePath(
            episodeID: episode.episodeID,
            sourceAudioURL: URL(string: episode.audioURL!)!
        )
        #expect(fileStore.fileExists(relativePath: relativePath) == false)
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

        try await downloader.download(from: sourceURL, to: destinationURL) { bytesReceived, bytesExpected in
            progressEvents.append((bytesReceived, bytesExpected))
        }

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
        let appModel = OpenCastAppModel(downloads: downloadStore)
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
        let appModel = OpenCastAppModel(downloads: downloadStore)
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
        let failedEpisode = makeEpisode(episodeID: "missing-audio")
        failedEpisode.audioURL = nil
        let unrelatedEpisode = makeEpisode(episodeID: "playable-audio")

        store.startDownload(for: failedEpisode, modelContext: context)

        let expectedMessage = EpisodeDownloadError.invalidAudioURL.localizedDescription
        #expect(store.lastErrorMessage == expectedMessage)
        #expect(store.lastErrorMessage(for: failedEpisode.episodeID) == expectedMessage)
        #expect(store.lastErrorMessage(for: unrelatedEpisode.episodeID) == nil)
    }

    @Test("Unsubscribe removes only downloads for that feed")
    func unsubscribeRemovesOnlyDownloadsForThatFeed() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let libraryStore = LibraryStore()
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
        libraryStore.load(modelContext: context)
        downloadStore.load(modelContext: context)

        libraryStore.unsubscribe(
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

    private func makeEpisode(episodeID: String) -> EpisodeCacheRecord {
        EpisodeCacheRecord(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode",
            duration: 120,
            audioURL: "https://example.com/\(episodeID).mp3",
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
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
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
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        try Data("partial".utf8).write(to: temporaryURL, options: .atomic)
        await progress(7, 100)

        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }
}
