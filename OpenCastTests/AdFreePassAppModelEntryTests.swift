import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass app model entry")
struct AdFreePassAppModelEntryTests {
    @Test("Detect Ads enqueues a manual pass and arms the session exactly once per drain")
    func detectAdsEnqueuesAndArmsExactlyOnce() async throws {
        let fixture = try await makeFixture()
        let first = makeEpisode(episodeID: "app-entry-1")
        let second = makeEpisode(episodeID: "app-entry-2")

        fixture.appModel.startAdFreePass(for: first, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.adFreePass.activeEpisodeID == first.episodeID
        })
        #expect(fixture.scheduler.submitCallCount == 1)

        // Appending while the session is armed never resubmits (one task per drain).
        fixture.appModel.startAdFreePass(for: second, modelContext: fixture.context)
        fixture.appModel.startAdFreePass(for: first, modelContext: fixture.context)

        #expect(fixture.appModel.adFreePass.queueItems.map(\.episodeID) == [second.episodeID])
        #expect(fixture.scheduler.submitCallCount == 1)
    }

    @Test("The Sound Lab megaphone is a wrapper over the same enqueue path")
    func soundLabMegaphoneWrapsSameEntry() async throws {
        let fixture = try await makeFixture()
        let episode = makeEpisode(episodeID: "app-entry-wrapper")
        try fixture.appModel.playback.load(Episode(
            id: EpisodeID(rawValue: episode.episodeID),
            podcastID: PodcastID(rawValue: episode.podcastID),
            podcastTitle: episode.podcastTitle,
            title: episode.title,
            duration: episode.duration,
            audioURL: URL(string: episode.audioURL ?? "https://example.com/audio.mp3")
        ), startPosition: 0)

        fixture.appModel.startOrContinueAdFreePassForCurrentEpisode(modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.adFreePass.activeEpisodeID == episode.episodeID
        })
        #expect(fixture.scheduler.submitCallCount == 1)

        // Re-tapping through the context-menu entry is idempotent with the
        // megaphone-started pass — one shared path.
        fixture.appModel.startAdFreePass(for: episode, modelContext: fixture.context)
        #expect(fixture.appModel.adFreePass.queueItems.isEmpty)
        #expect(fixture.scheduler.submitCallCount == 1)
    }

    @Test("Playing an opted-in show auto-enqueues once without arming the session")
    func playTriggeredAutoPassEnqueuesWithoutArming() async throws {
        let fixture = try await makeFixture()
        let episode = makeEpisode(episodeID: "app-entry-auto-play")
        try await seedSubscription(
            feedURL: episode.podcastID,
            isAdAutoDetectEnabled: true,
            fixture: fixture
        )

        try fixture.appModel.playEpisode(episode, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.adFreePass.activeEpisodeID == episode.episodeID
        })
        // Auto passes never arm background continuation.
        #expect(fixture.scheduler.submitCallCount == 0)

        // Playing the same episode again while its pass runs is a no-op.
        try fixture.appModel.playEpisode(episode, modelContext: fixture.context)
        #expect(fixture.appModel.adFreePass.queueItems.isEmpty)
        #expect(fixture.scheduler.submitCallCount == 0)
    }

    @Test("Play-triggered auto passes insert at the queue front behind the active item")
    func playTriggeredAutoPassInsertsAtFront() async throws {
        let fixture = try await makeFixture()
        let manualFirst = makeEpisode(episodeID: "app-entry-manual-first")
        let autoPlayed = makeEpisode(episodeID: "app-entry-auto-front")
        let manualSecond = makeEpisode(episodeID: "app-entry-manual-second")
        try await seedSubscription(
            feedURL: autoPlayed.podcastID,
            isAdAutoDetectEnabled: true,
            fixture: fixture
        )

        fixture.appModel.startAdFreePass(for: manualFirst, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.adFreePass.activeEpisodeID == manualFirst.episodeID
        })

        fixture.appModel.startAdFreePass(for: manualSecond, modelContext: fixture.context)
        try fixture.appModel.playEpisode(autoPlayed, modelContext: fixture.context)

        #expect(await waitUntil {
            fixture.appModel.adFreePass.queueItems.first?.episodeID == autoPlayed.episodeID
        })
        let pending = fixture.appModel.adFreePass.queueItems
        #expect(pending.map(\.episodeID) == [autoPlayed.episodeID, manualSecond.episodeID])
        #expect(pending.first?.origin == .auto)
        // Only the manual entry armed the session.
        #expect(fixture.scheduler.submitCallCount == 1)

        // A second play of the queued episode never duplicates it.
        try fixture.appModel.playEpisode(autoPlayed, modelContext: fixture.context)
        #expect(fixture.appModel.adFreePass.queueItems.map(\.episodeID) == [
            autoPlayed.episodeID, manualSecond.episodeID
        ])
    }

    @Test("Playing a show without the opt-in never enqueues an auto pass")
    func playWithoutOptInNeverEnqueues() async throws {
        let fixture = try await makeFixture()
        let episode = makeEpisode(episodeID: "app-entry-no-opt-in")
        try await seedSubscription(
            feedURL: episode.podcastID,
            isAdAutoDetectEnabled: false,
            fixture: fixture
        )

        try fixture.appModel.playEpisode(episode, modelContext: fixture.context)

        #expect(fixture.appModel.adFreePass.activeEpisodeID == nil)
        #expect(fixture.appModel.adFreePass.queueItems.isEmpty)
        #expect(fixture.scheduler.submitCallCount == 0)
    }

    @Test("First background arm requests provisional authorization only when notDetermined")
    func firstArmRequestsProvisionalAuthorization() async throws {
        let fixture = try await makeFixture()
        fixture.notificationCenter.authorizationStatusValue = .notDetermined
        let episode = makeEpisode(episodeID: "app-entry-provisional")

        fixture.appModel.startAdFreePass(for: episode, modelContext: fixture.context)

        #expect(await waitUntil {
            fixture.notificationCenter.provisionalRequestCount == 1
        })
        #expect(fixture.notificationCenter.authorizationStatusValue == .provisional)
    }

    @Test("Arming never requests authorization once the user has decided")
    func armSkipsAuthorizationRequestWhenDecided() async throws {
        let fixture = try await makeFixture()
        fixture.notificationCenter.authorizationStatusValue = .denied
        let episode = makeEpisode(episodeID: "app-entry-provisional-denied")

        fixture.appModel.startAdFreePass(for: episode, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.adFreePass.activeEpisodeID == episode.episodeID
        })
        #expect(await waitUntil {
            fixture.notificationCenter.authorizationStatusReadCount >= 1
        })

        #expect(fixture.notificationCenter.provisionalRequestCount == 0)
    }

    @Test("Download menu state derives from the download record and local file")
    func downloadMenuStateDerivesFromRecord() async throws {
        let fixture = try await makeFixture()
        let episode = makeEpisode(episodeID: "app-entry-download")

        #expect(fixture.appModel.downloadMenuState(for: episode) == .available)

        // A live in-flight download (the fixture downloader hangs) disables
        // the action without hiding it.
        fixture.appModel.downloads.startDownload(for: episode, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.downloads.record(for: episode.episodeID)?.state == .downloading
                && fixture.appModel.downloads.byteProgress(for: episode.episodeID)?.bytesReceived == 7
        })
        #expect(fixture.appModel.downloadMenuState(for: episode) == .downloading)
        fixture.appModel.downloads.pauseDownload(episodeID: episode.episodeID, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.downloads.record(for: episode.episodeID)?.state == .paused
        })
        #expect(fixture.appModel.downloadMenuState(for: episode) == .available)

        // A completed download with its file on disk hides the action
        // (fresh fixture: the record is seeded pre-load like a relaunch).
        let downloadedFixture = try await makeFixture()
        let sourceURL = URL(string: episode.audioURL ?? "https://example.com/audio.mp3")!
        let relativePath = downloadedFixture.downloadFileStore.relativePath(
            episodeID: episode.episodeID,
            sourceAudioURL: sourceURL
        )
        try downloadedFixture.downloadFileStore.prepareDownloadsDirectory()
        let data = Data("downloaded".utf8)
        try data.write(
            to: downloadedFixture.downloadFileStore.fileURL(relativePath: relativePath),
            options: .atomic
        )
        downloadedFixture.context.insert(EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        ))
        try downloadedFixture.context.save()
        await downloadedFixture.appModel.downloads.load(modelContext: downloadedFixture.context)
        #expect(downloadedFixture.appModel.downloadMenuState(for: episode) == .downloaded)
    }

    // MARK: - Fixture

    @MainActor
    private struct EntryFixture {
        let appModel: OpenCastAppModel
        let context: ModelContext
        let scheduler: EntryFakeScheduler
        let downloadFileStore: EpisodeDownloadFileStore
        let notificationCenter: FakeAdFreePassNotificationCenter
    }

    private func makeFixture() async throws -> EntryFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let downloads = DownloadStore(
            downloader: HangingEntryAudioDownloader(),
            fileStore: downloadFileStore
        )
        let scheduler = EntryFakeScheduler()
        let notificationCenter = FakeAdFreePassNotificationCenter()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptions: EpisodeTranscriptionStore(
                fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
            ),
            adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession(scheduler: scheduler),
            allowsAutomaticFeedRefresh: false,
            adFreePassNotificationCenter: notificationCenter
        )
        await downloads.load(modelContext: context)
        return EntryFixture(
            appModel: appModel,
            context: context,
            scheduler: scheduler,
            downloadFileStore: downloadFileStore,
            notificationCenter: notificationCenter
        )
    }

    private func seedSubscription(
        feedURL: String,
        isAdAutoDetectEnabled: Bool,
        fixture: EntryFixture
    ) async throws {
        fixture.context.insert(SubscriptionRecord(
            feedURL: feedURL,
            title: "Example Show",
            isAdAutoDetectEnabled: isAdAutoDetectEnabled
        ))
        try fixture.context.save()
        await fixture.appModel.library.load(modelContext: fixture.context)
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            title: "Example Episode \(episodeID)",
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAdFreePassEntryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<120 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

private struct HangingEntryAudioDownloader: EpisodeAudioDownloading {
    nonisolated func download(
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

private final class EntryFakeScheduler: AdFreePassContinuedTaskScheduling {
    let supportsGPUResources = false
    private(set) var submitCallCount = 0
    private(set) var cancelledIdentifiers: [String] = []

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AdFreePassContinuedTaskHandle) -> Void
    ) -> Bool {
        true
    }

    func submit(identifier: String, title: String, subtitle: String, requiresGPU: Bool) throws {
        submitCallCount += 1
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }
}
