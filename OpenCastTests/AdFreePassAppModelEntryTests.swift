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

    @Test("A play after Remove Played in the same session enqueues an automatic pass over a retained completed outcome")
    func playAfterRemovePlayedEnqueuesOverRetainedCompletion() async throws {
        let fixture = try await makeFixture()
        let episode = makeEpisode(episodeID: "app-entry-replay-completed")
        try await seedSubscription(feedURL: episode.podcastID, isAdAutoDetectEnabled: true, fixture: fixture)
        try await seedAttachedAnalysis(for: episode, fixture: fixture)

        // A pass over the attached analysis completes without a run.
        fixture.appModel.startAdFreePass(for: episode, modelContext: fixture.context)
        guard case .completed = await waitForRetainedOutcome(of: episode, fixture: fixture) else {
            Issue.record("Expected the pass over the attached analysis to complete.")
            return
        }

        _ = fixture.appModel.markEpisodePlayed(episode, modelContext: fixture.context)
        fixture.appModel.deletePlayedDownloads(modelContext: fixture.context)
        #expect(fixture.appModel.downloads.record(for: episode.episodeID) == nil)
        guard case .completed = fixture.appModel.adFreePass.queueStatus(for: episode.episodeID) else {
            Issue.record("Expected the session to retain the completed outcome.")
            return
        }

        try fixture.appModel.playEpisode(episode, modelContext: fixture.context)

        // The automatic pass downloads the audio again (the fixture's
        // download hangs, holding it active).
        #expect(await waitUntil {
            fixture.appModel.adFreePass.activeItem?.episodeID == episode.episodeID
        })
        #expect(fixture.appModel.adFreePass.activeItem?.origin == .auto)
        #expect(fixture.scheduler.submitCallCount == 1)
    }

    @Test("A play after the download's removal does not retry a pass that failed this session")
    func playAfterRemovalDoesNotRetryRetainedFailure() async throws {
        let fixture = try await makeFixture(downloader: ScriptedEpisodeAudioDownloader(contents: nil))
        let failed = makeEpisode(episodeID: "app-entry-replay-failed")
        let control = makeEpisode(episodeID: "app-entry-replay-control")
        try await seedSubscription(feedURL: failed.podcastID, isAdAutoDetectEnabled: true, fixture: fixture)
        try await seedAttachedAnalysis(for: failed, fixture: fixture)
        let download = try #require(fixture.appModel.downloads.record(for: failed.episodeID))
        fixture.appModel.deleteDownload(download, modelContext: fixture.context)

        // Detect Ads Again by hand: the download it needs fails.
        fixture.appModel.startAdFreePass(for: failed, modelContext: fixture.context)
        guard case .failed = await waitForRetainedOutcome(of: failed, fixture: fixture) else {
            Issue.record("Expected the manual pass to fail at its download.")
            return
        }
        // Cached, so a play that reached the policy would enqueue within its
        // first turn, before the control's play below.
        #expect(await fixture.appModel.adFreePass.currentCompletedAnalysisVerdict(
            for: failed.episodeID,
            transcriptions: fixture.appModel.transcriptions,
            adAnalyses: fixture.appModel.adAnalyses
        ))

        try fixture.appModel.playEpisode(failed, modelContext: fixture.context)
        try fixture.appModel.playEpisode(control, modelContext: fixture.context)

        // The never-scanned control is admitted, and its drain ran nothing
        // else.
        guard case .failed = await waitForRetainedOutcome(of: control, fixture: fixture) else {
            Issue.record("Expected the control's automatic pass to run and fail at its download.")
            return
        }
        #expect(fixture.appModel.adFreePass.drainOutcomes.map(\.episodeID) == [control.episodeID])
    }

    // MARK: - Fixture

    @MainActor
    private struct EntryFixture {
        let appModel: OpenCastAppModel
        let context: ModelContext
        let scheduler: EntryFakeScheduler
        let downloadFileStore: EpisodeDownloadFileStore
        let transcriptFileStore: EpisodeTranscriptFileStore
        let adAnalysisFileStore: EpisodeAdAnalysisFileStore
        let notificationCenter: FakeAdFreePassNotificationCenter
    }

    private func makeFixture(
        downloader: any EpisodeAudioDownloading = HangingEntryAudioDownloader()
    ) async throws -> EntryFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let downloads = DownloadStore(
            downloader: downloader,
            fileStore: downloadFileStore
        )
        let scheduler = EntryFakeScheduler()
        let notificationCenter = FakeAdFreePassNotificationCenter()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            adAnalyses: EpisodeAdAnalysisStore(fileStore: adAnalysisFileStore),
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
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            notificationCenter: notificationCenter
        )
    }

    /// A hashed completed download, a completed transcript of its bytes and
    /// a current analysis of that transcript, loaded as at launch: an
    /// episode whose analysis is attached.
    private func seedAttachedAnalysis(for episode: EpisodeListItemSnapshot, fixture: EntryFixture) async throws {
        let sourceURL = URL(string: episode.audioURL ?? "https://example.com/audio.mp3")!
        let contents = Data("downloaded \(episode.episodeID)".utf8)
        let sourceSHA256 = OpenCastSHA256.hash(contents)
        let downloadPath = fixture.downloadFileStore.relativePath(episodeID: episode.episodeID, sourceAudioURL: sourceURL)
        try fixture.downloadFileStore.prepareDownloadsDirectory()
        try contents.write(to: fixture.downloadFileStore.fileURL(relativePath: downloadPath), options: .atomic)
        let download = EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: downloadPath,
            state: .completed,
            bytesReceived: Int64(contents.count),
            bytesExpected: Int64(contents.count)
        )
        download.sourceFileSHA256 = sourceSHA256
        fixture.context.insert(download)

        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 4,
            text: "This episode is brought to you by Example.",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        let transcript = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            sourceFileByteCount: Int64(contents.count),
            sourceFileSHA256: sourceSHA256,
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 30,
            checkpoints: [],
            segments: [segment],
            text: segment.text,
            timings: EpisodeTranscriptTimings(),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let transcriptPath = fixture.transcriptFileStore.relativePath(episodeID: episode.episodeID, fingerprint: "transcript")
        try fixture.transcriptFileStore.write(transcript, relativePath: transcriptPath)
        fixture.context.insert(EpisodeTranscriptRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: transcript.sourceAudioURL,
            sourceFileByteCount: transcript.sourceFileByteCount,
            sourceFileSHA256: sourceSHA256,
            modelIdentifier: transcript.modelIdentifier,
            modelVersion: transcript.modelVersion,
            modelTreeSHA256: transcript.modelTreeSHA256,
            languageCode: transcript.languageCode,
            state: .completed,
            audioDuration: transcript.audioDuration,
            completedDuration: transcript.audioDuration,
            checkpointCount: 0,
            transcriptRelativePath: transcriptPath,
            createdAt: createdAt,
            updatedAt: createdAt
        ))

        let fingerprint = fixture.adAnalysisFileStore.transcriptFingerprint(for: transcript)
        let analysis = EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            requestID: "request",
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: transcript.segments.count,
            model: "gemini-test",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [EpisodeAdAnalysisSpan(
                id: 0,
                kind: .hostReadAd,
                label: "Sponsor",
                startSegmentID: 0,
                endSegmentID: 0,
                startTime: 0,
                endTime: 4,
                confidence: 0.9,
                evidenceQuote: "brought to you"
            )],
            warnings: [],
            usage: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let analysisPath = fixture.adAnalysisFileStore.relativePath(
            episodeID: episode.episodeID,
            transcriptFingerprint: fingerprint
        )
        try fixture.adAnalysisFileStore.write(analysis, relativePath: analysisPath)
        fixture.context.insert(EpisodeAdAnalysisRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: transcript.segments.count,
            transcriptState: .completed,
            state: .completed,
            analysisRelativePath: analysisPath,
            model: analysis.model,
            policy: analysis.policy,
            spanCount: analysis.spans.count,
            warningCount: 0,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        try fixture.context.save()
        await fixture.appModel.downloads.load(modelContext: fixture.context)
        fixture.appModel.loadLocalTranscriptionState(modelContext: fixture.context)
    }

    /// The session's retained outcome for `episode` once its drain is over.
    private func waitForRetainedOutcome(
        of episode: EpisodeListItemSnapshot,
        fixture: EntryFixture
    ) async -> AdFreePassQueueEpisodeStatus? {
        let coordinator = fixture.appModel.adFreePass
        let settled = await waitUntil {
            coordinator.queueState == .idle
                && coordinator.activeEpisodeID == nil
                && coordinator.drainOutcomes.contains { $0.episodeID == episode.episodeID }
        }
        return settled ? coordinator.queueStatus(for: episode.episodeID) : nil
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
