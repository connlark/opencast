import Foundation
import OpenCastCore
import OpenCastPlayback
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Data nuke")
struct DataNukeTests {
    @Test("Confirmation text ignores case and non-letters")
    func confirmationTextIgnoresCaseAndNonLetters() {
        #expect(DataNukeConfirmation.isConfirmed("NUKE"))
        #expect(DataNukeConfirmation.isConfirmed("NuKe"))
        #expect(DataNukeConfirmation.isConfirmed("n u k e"))
        #expect(!DataNukeConfirmation.isConfirmed("delete everything"))
    }

    @Test("Nuke removes synced local rows files caches preferences and playback state")
    func nukeRemovesRowsFilesCachesPreferencesAndPlaybackState() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        let appModel = OpenCastAppModel(
            cacheController: cacheController,
            library: LibraryStore(),
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        let episode = try seedAllData(fileStore: fileStore, context: context)
        try writeCacheFixture(in: cacheController.feedCacheDirectory, fileName: "feed.cache")
        try writeCacheFixture(in: cacheController.artworkCacheDirectory, fileName: "artwork.cache")
        try writeOrphanPartialDownload(fileStore: fileStore)

        appModel.library.load(modelContext: context)
        appModel.downloads.load(modelContext: context)
        appModel.appearanceSettings.load(modelContext: context)
        appModel.playbackSettings.load(modelContext: context, playback: appModel.playback)
        appModel.onboardingState.load(modelContext: context)
        _ = appModel.setAppearanceMode(.dark, modelContext: context)
        _ = appModel.setVoiceBoostMode(.globalOff, modelContext: context)
        _ = appModel.setSkipBackwardOption(.sixty, modelContext: context)
        _ = appModel.setSkipForwardOption(.five, modelContext: context)
        _ = appModel.onboardingState.markCompleted(modelContext: context)
        try appModel.playback.load(appModel.library.domainEpisode(for: episode), startPosition: 42)
        appModel.lastPlaybackError = "Previous playback failure"
        appModel.isNowPlayingPresented = true

        try await appModel.nukeAllData(modelContext: context)

        try expectAllTablesEmpty(context)
        #expect(appModel.library.subscriptions.isEmpty)
        #expect(appModel.library.episodes.isEmpty)
        #expect(appModel.downloads.records.isEmpty)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(!appModel.isNowPlayingPresented)
        #expect(appModel.appearanceSettings.mode == .system)
        #expect(appModel.playbackSettings.voiceBoostMode == .globalOn)
        #expect(appModel.playbackSettings.isVoiceBoostEnabled)
        #expect(appModel.playbackSettings.skipBackwardOption == .defaultBackward)
        #expect(appModel.playbackSettings.skipForwardOption == .defaultForward)
        #expect(!appModel.onboardingState.isCompleted)
        #expect(appModel.dataNukeCompletionID == 1)
        #expect(appModel.lastDataNukeErrorMessage == nil)
        #expect(try regularFiles(in: cacheController.feedCacheDirectory).isEmpty)
        #expect(try regularFiles(in: cacheController.artworkCacheDirectory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileStore.downloadsDirectory.path))
    }

    @Test("Unavailable iCloud aborts before deleting anything")
    func unavailableICloudAbortsBeforeDeletingAnything() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        let appModel = OpenCastAppModel(
            cacheController: cacheController,
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.noAccount])
            ),
            allowsAutomaticFeedRefresh: false
        )
        let episode = try seedAllData(fileStore: fileStore, context: context)
        try writeCacheFixture(in: cacheController.feedCacheDirectory, fileName: "feed.cache")
        try writeCacheFixture(in: cacheController.artworkCacheDirectory, fileName: "artwork.cache")
        let downloadPath = try #require(
            try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).first?.localRelativePath
        )

        do {
            try await appModel.nukeAllData(modelContext: context)
            Issue.record("Expected unavailable iCloud to abort nuke.")
        } catch DataNukeError.iCloudUnavailable(.noAccount) {
        } catch {
            Issue.record("Expected unavailable iCloud, got \(error).")
        }

        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PodcastCacheRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<EpisodeCacheRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<RefreshLogRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).count == 1)
        #expect(FileManager.default.fileExists(atPath: cacheController.feedCacheDirectory.appending(path: "feed.cache").path))
        #expect(FileManager.default.fileExists(atPath: cacheController.artworkCacheDirectory.appending(path: "artwork.cache").path))
        #expect(fileStore.fileExists(relativePath: downloadPath))
        #expect(appModel.dataNukeCompletionID == 0)
        #expect(appModel.lastDataNukeErrorMessage?.contains("iCloud is not available") == true)
        #expect(appModel.isNukingData == false)
        #expect(episode.episodeID == "nuke-episode")
    }

    @Test("Nuke force-refreshes recent iCloud status before deleting")
    func nukeForceRefreshesRecentICloudStatusBeforeDeleting() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let provider = SequencedCloudKitAccountStatusProvider(statuses: [.available, .noAccount])
        let syncStatus = SyncStatusStore(accountStatusProvider: provider)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let appModel = OpenCastAppModel(
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: syncStatus,
            allowsAutomaticFeedRefresh: false
        )

        _ = try seedAllData(fileStore: fileStore, context: context)
        await syncStatus.refreshAccountStatus()

        do {
            try await appModel.nukeAllData(modelContext: context)
            Issue.record("Expected forced iCloud recheck to abort nuke.")
        } catch DataNukeError.iCloudUnavailable(.noAccount) {
        } catch {
            Issue.record("Expected no-account iCloud status, got \(error).")
        }

        #expect(await provider.callCount == 2)
        #expect(syncStatus.accountStatus == .noAccount)
        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).count == 1)
    }

    @Test("Refresh finishing after nuke cannot recreate cache rows")
    func refreshFinishingAfterNukeCannotRecreateCacheRows() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/race.xml"
        let feedService = HangingFeedService()
        let appModel = OpenCastAppModel(
            library: LibraryStore(feedService: feedService),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Race Show"))
        try context.save()
        appModel.library.load(modelContext: context)

        let refreshTask = Task { @MainActor in
            await appModel.library.refresh(feedURL: feedURL, modelContext: context)
        }
        #expect(await feedService.waitForRequest())

        try await appModel.nukeAllData(modelContext: context)
        await feedService.release(
            makeSnapshot(
                feedURL: feedURL,
                podcastTitle: "Race Show Updated",
                episodeID: "race-new-episode"
            )
        )
        await refreshTask.value

        try expectAllTablesEmpty(context)
        #expect(appModel.library.episodes.isEmpty)
        #expect(appModel.library.refreshLogs.isEmpty)
    }

    @Test("Cache clearing failure after row deletion keeps runtime state clear")
    func cacheClearingFailureAfterRowDeletionKeepsRuntimeStateClear() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        let appModel = OpenCastAppModel(
            cacheController: cacheController,
            library: LibraryStore(),
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        _ = try seedAllData(fileStore: fileStore, context: context)
        try FileManager.default.removeItem(at: cacheController.artworkCacheDirectory)
        try Data("not a directory".utf8).write(to: cacheController.artworkCacheDirectory, options: .atomic)

        appModel.library.load(modelContext: context)
        appModel.downloads.load(modelContext: context)
        appModel.appearanceSettings.load(modelContext: context)
        _ = appModel.setAppearanceMode(.dark, modelContext: context)

        var didFailCacheClearing = false
        do {
            try await appModel.nukeAllData(modelContext: context)
            Issue.record("Expected cache clearing to fail after row deletion.")
        } catch {
            didFailCacheClearing = true
        }

        #expect(didFailCacheClearing)
        try expectAllTablesEmpty(context)
        #expect(appModel.library.subscriptions.isEmpty)
        #expect(appModel.library.episodes.isEmpty)
        #expect(appModel.library.progressRecords.isEmpty)
        #expect(appModel.library.refreshLogs.isEmpty)
        #expect(appModel.downloads.records.isEmpty)
        #expect(appModel.appearanceSettings.mode == .system)
        #expect(appModel.lastDataNukeErrorMessage != nil)
        #expect(cacheController.lastErrorMessage != nil)
        #expect(!appModel.isNukingData)
    }

    private func seedAllData(
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws -> EpisodeCacheRecord {
        let feedURL = "https://example.com/nuke.xml"
        let sourceAudioURL = URL(string: "https://example.com/nuke-episode.mp3")!
        let episode = EpisodeCacheRecord(
            episodeID: "nuke-episode",
            podcastID: feedURL,
            podcastTitle: "Nuke Show",
            title: "Nuke Episode",
            duration: 300,
            audioURL: sourceAudioURL.absoluteString,
            artworkURL: "https://example.com/art.jpg",
            guid: "nuke-episode"
        )
        let downloadPath = fileStore.relativePath(
            episodeID: episode.episodeID,
            sourceAudioURL: sourceAudioURL
        )

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Nuke Show"))
        context.insert(PodcastCacheRecord(feedURL: feedURL, title: "Nuke Show"))
        context.insert(episode)
        context.insert(EpisodeProgressRecord(episodeID: episode.episodeID, podcastID: feedURL, position: 120))
        context.insert(RefreshLogRecord(feedURL: feedURL, finishedAt: .now))
        context.insert(LocalPreferenceRecord(key: "custom.preference", value: "stored"))
        try fileStore.prepareDownloadsDirectory()
        try Data("downloaded audio".utf8).write(
            to: fileStore.fileURL(relativePath: downloadPath),
            options: .atomic
        )
        context.insert(
            EpisodeDownloadRecord(
                episodeID: episode.episodeID,
                podcastID: feedURL,
                sourceAudioURL: sourceAudioURL.absoluteString,
                localRelativePath: downloadPath,
                state: .completed,
                bytesReceived: 16,
                bytesExpected: 16
            )
        )
        try context.save()
        return episode
    }

    private func expectAllTablesEmpty(_ context: ModelContext) throws {
        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PodcastCacheRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeCacheRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RefreshLogRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
    }

    private func makeSnapshot(
        feedURL: String,
        podcastTitle: String,
        episodeID: String
    ) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: podcastTitle
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: episodeID),
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: "Race New Episode",
                    audioURL: URL(string: "https://example.com/\(episodeID).mp3"),
                    guid: episodeID
                )
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastDataNukeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCacheFixture(in directory: URL, fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: directory.appending(path: fileName), options: .atomic)
    }

    private func writeOrphanPartialDownload(fileStore: EpisodeDownloadFileStore) throws {
        try fileStore.prepareDownloadsDirectory()
        try Data("partial".utf8).write(
            to: fileStore.downloadsDirectory.appending(path: "orphan.partial"),
            options: .atomic
        )
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else {
                return nil
            }
            return url
        }
    }
}

private actor SequencedCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    private var statuses: [SyncAccountStatus]
    private(set) var callCount = 0

    init(statuses: [SyncAccountStatus]) {
        self.statuses = statuses
    }

    func accountStatus() async throws -> SyncAccountStatus {
        callCount += 1
        guard !statuses.isEmpty else {
            return .couldNotDetermine
        }

        return statuses.removeFirst()
    }
}

private actor HangingFeedService: FeedService {
    private var didRequest = false
    private var continuation: CheckedContinuation<FeedSnapshot, Never>?

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        didRequest = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ snapshot: FeedSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }

    func waitForRequest() async -> Bool {
        for _ in 0..<6_000 {
            if didRequest {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        return didRequest
    }
}
