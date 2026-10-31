import Foundation
import OpenCastAnalysis
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Data nuke")
struct DataNukeTests {
    private let seededFeedURL = "https://example.com/nuke.xml"

    @Test("Nuke deregisters services after store nukes and before the row wipe")
    func serviceDeregistrationOrdering() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let suspension = AppAttestSuspension()
        context.insert(SubscriptionRecord(feedURL: seededFeedURL, title: "Nuke Show"))
        context.insert(EpisodeAdAnalysisRecord(episodeID: "episode", podcastID: seededFeedURL))
        context.insert(EpisodeTranscriptAnalysisRecord(episodeID: "episode", podcastID: seededFeedURL))
        context.insert(EpisodeTranscriptRecord(episodeID: "episode", podcastID: seededFeedURL, sourceAudioURL: "https://example.com/audio.mp3"))
        try context.save()
        var called = false
        let verifyOrdering: @MainActor @Sendable () -> Void = {
            called = true
            #expect(suspension.isSuspended)
            #expect((try? context.fetchCount(FetchDescriptor<EpisodeAdAnalysisRecord>())) == 0)
            #expect((try? context.fetchCount(FetchDescriptor<EpisodeTranscriptAnalysisRecord>())) == 0)
            #expect((try? context.fetchCount(FetchDescriptor<EpisodeTranscriptRecord>())) == 0)
            #expect((try? context.fetchCount(FetchDescriptor<SubscriptionRecord>())) == 1)
        }
        let appModel = try deregistrationAppModel(suspension: suspension, services: .init(slots: [
            .trialProxy: { _ in await verifyOrdering(); return nil }
        ]))
        try await appModel.nukeAllData(modelContext: context)
        #expect(called)
        #expect(try context.fetchCount(FetchDescriptor<SubscriptionRecord>()) == 0)
        #expect(appModel.dataNukeCompletionID == 1)
        #expect(!suspension.isSuspended)
    }

    @Test("Every slot failing still completes the nuke and keeps retry credentials")
    func allServiceFailuresStillComplete() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: seededFeedURL, title: "Nuke Show"))
        try context.save()
        let release = DeregistrationTestLatch()
        let serverFailure = DeregistrationTestSlot(transport: .init(replies: [.init(status: 500, body: "{}")]))
        let assertionFailure = DeregistrationTestSlot(attest: .init(assertionError: URLError(.cannotConnectToHost)))
        let timeout = DeregistrationTestSlot(transport: .init(release: release))
        let trialFailure = DeregistrationTestSlot(transport: .init(replies: [.init(status: 503, body: "{}")]))
        let slots = [serverFailure, assertionFailure, timeout, trialFailure]
        defer { release.release(); for slot in slots { try? slot.keychain.deleteAll() } }
        for slot in slots { _ = try slot.registerLocally() }
        let suspension = AppAttestSuspension()
        let appModel = try deregistrationAppModel(suspension: suspension, services: .init(slots: [
            .transcriptAnalysis: { _ in serverFailure.deregistration() },
            .adAnalysis: { _ in assertionFailure.deregistration() },
            .remoteTranscription: { _ in timeout.deregistration() },
            .trialProxy: { _ in trialFailure.deregistration(keepsInstallID: true) }
        ], timeoutSeconds: 0.05))
        try await appModel.nukeAllData(modelContext: context)
        #expect(try context.fetchCount(FetchDescriptor<SubscriptionRecord>()) == 0)
        #expect(appModel.dataNukeCompletionID == 1)
        #expect(appModel.lastAnalysisServicesDeregistrationErrorMessage != nil)
        #expect(!suspension.isSuspended)
        for slot in slots { #expect(try slot.keychain.loadAppAttestKeyID() == "old-key") }
    }

    @Test("Failure after suspension closes reopens admission in the runner catch path")
    func failureReopensSuspension() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let root = try makeTemporaryDirectory()
        let cache = OpenCastCacheController(rootDirectory: root.appending(path: "Cache"))
        try FileManager.default.removeItem(at: cache.artworkCacheDirectory)
        try Data("not a directory".utf8).write(to: cache.artworkCacheDirectory)
        let suspension = AppAttestSuspension()
        let runner = DataNukeRunner(
            syncStatus: SyncStatusStore(accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: EpisodeDownloadFileStore(baseDirectory: root)),
            transcriptions: EpisodeTranscriptionStore(fileStore: EpisodeTranscriptFileStore(baseDirectory: root)),
            adAnalyses: EpisodeAdAnalysisStore(client: UnusedEpisodeAdAnalysisClient(), fileStore: EpisodeAdAnalysisFileStore(baseDirectory: root)),
            transcriptAnalyses: EpisodeTranscriptAnalysisStore(),
            transcriptionModels: TranscriptionModelStore(),
            cacheController: cache, siriMediaDiscovery: SiriMediaDiscovery(), appAttestSuspension: suspension
        )
        runner.deregisterServices = { suspension.suspend() }
        // Hold admission closed so the error handler itself must reopen it.
        runner.resetRuntime = { _ in #expect(suspension.isSuspended) }
        await #expect(throws: (any Error).self) { try await runner.run(modelContext: context) }
        #expect(!suspension.isSuspended)
        #expect(runner.completionID == 0)
        #expect(runner.lastErrorMessage != nil)
    }

    private func deregistrationAppModel(
        suspension: AppAttestSuspension,
        services: AnalysisServicesDeregistration
    ) throws -> OpenCastAppModel {
        let root = try makeTemporaryDirectory()
        return OpenCastAppModel(
            appAttestSuspension: suspension,
            cacheController: OpenCastCacheController(rootDirectory: root.appending(path: "Caches")),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: EpisodeDownloadFileStore(baseDirectory: root)),
            transcriptions: EpisodeTranscriptionStore(fileStore: EpisodeTranscriptFileStore(baseDirectory: root)),
            adAnalyses: EpisodeAdAnalysisStore(client: UnusedEpisodeAdAnalysisClient(), fileStore: EpisodeAdAnalysisFileStore(baseDirectory: root)),
            analysisServicesDeregistration: services,
            syncStatus: SyncStatusStore(accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])),
            allowsAutomaticFeedRefresh: false
        )
    }

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
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: fileStore.baseDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: cacheController,
            library: LibraryStore(localCache: localCache),
            downloads: DownloadStore(fileStore: fileStore),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            adAnalyses: EpisodeAdAnalysisStore(
                client: UnusedEpisodeAdAnalysisClient(),
                fileStore: adAnalysisFileStore
            ),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        let seededEpisode = try seedAllData(
            fileStore: fileStore,
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            context: context
        )
        try writeCacheFixture(in: cacheController.feedCacheDirectory, fileName: "feed.cache")
        try writeCacheFixture(in: cacheController.artworkCacheDirectory, fileName: "artwork.cache")
        try writeOrphanPartialDownload(fileStore: fileStore)

        await appModel.library.load(modelContext: context)
        await appModel.downloads.load(modelContext: context)
        appModel.appearanceSettings.load(modelContext: context)
        appModel.recentSearches.load(modelContext: context)
        appModel.playbackSettings.load(modelContext: context, playback: appModel.playback)
        appModel.onboardingState.load(modelContext: context)
        _ = appModel.setAppearanceMode(.dark, modelContext: context)
        appModel.appearanceSettings.setMinimizesTabBarOnScroll(true, modelContext: context)
        _ = appModel.setVoiceBoostMode(.globalOff, modelContext: context)
        _ = appModel.setSkipBackwardOption(.sixty, modelContext: context)
        _ = appModel.setSkipForwardOption(.five, modelContext: context)
        appModel.recentSearches.record("Erase Me", modelContext: context)
        _ = appModel.onboardingState.markCompleted(modelContext: context)
        let episode = try #require(appModel.library.episode(with: seededEpisode.episodeID))
        try appModel.playback.load(appModel.library.domainEpisode(for: episode), startPosition: 42)
        appModel.lastPlaybackError = "Previous playback failure"
        appModel.isNowPlayingPresented = true
        appModel.transcriptions.load(modelContext: context)
        appModel.adAnalyses.load(modelContext: context)
        #expect(appModel.recentSearches.queries == ["Erase Me"])
        #expect(!appModel.transcriptions.records.isEmpty)
        #expect(!appModel.adAnalyses.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: transcriptFileStore.transcriptsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: adAnalysisFileStore.analysesDirectory.path))

        try await appModel.nukeAllData(modelContext: context)

        try await expectAllTablesEmpty(context, localCache: localCache, activeFeedURL: seededFeedURL)
        #expect(appModel.library.subscriptions.isEmpty)
        #expect(appModel.library.episodes.isEmpty)
        #expect(appModel.downloads.records.isEmpty)
        #expect(appModel.transcriptions.records.isEmpty)
        #expect(appModel.adAnalyses.records.isEmpty)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(!appModel.isNowPlayingPresented)
        #expect(appModel.appearanceSettings.mode == .system)
        #expect(!appModel.appearanceSettings.minimizesTabBarOnScroll)
        #expect(appModel.recentSearches.queries.isEmpty)
        #expect(appModel.playbackSettings.voiceBoostMode == .perEpisode)
        #expect(appModel.playbackSettings.isVoiceBoostEnabled)
        #expect(appModel.playbackSettings.skipBackwardOption == .defaultBackward)
        #expect(appModel.playbackSettings.skipForwardOption == .defaultForward)
        #expect(!appModel.onboardingState.isCompleted)
        #expect(appModel.dataNukeCompletionID == 1)
        #expect(appModel.lastDataNukeErrorMessage == nil)
        #expect(try regularFiles(in: cacheController.feedCacheDirectory).isEmpty)
        #expect(try regularFiles(in: cacheController.artworkCacheDirectory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileStore.downloadsDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: transcriptFileStore.transcriptsDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: adAnalysisFileStore.analysesDirectory.path))
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
            appAttestSuspension: AppAttestSuspension(),
            cacheController: cacheController,
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
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
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).count == 1)
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
            appAttestSuspension: AppAttestSuspension(),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
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

    @Test("Nuke resets submitted ad-free pass background session")
    func nukeResetsSubmittedAdFreePassBackgroundSession() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let scheduler = DataNukeAdFreePassScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let temporaryDirectory = try makeTemporaryDirectory()
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(
                fileStore: EpisodeDownloadFileStore(
                    baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
                )
            ),
            adFreePassBackgroundSession: session,
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )

        session.arm(episodeTitle: "Submitted Before Nuke")

        try await appModel.nukeAllData(modelContext: context)
        session.arm(episodeTitle: "Submitted After Nuke")

        #expect(scheduler.cancelledIdentifiers.count == 3)
        #expect(scheduler.submitCallCount == 2)
    }

    @Test("Nuke cancels the transcript-analysis queue before the drain can start a fresh run")
    func nukeCancelsPendingTranscriptAnalysisQueue() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: fileStore.baseDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: ScriptedTranscriptAnalysisDrainClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
        )
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: cacheController,
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: fileStore),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            adAnalyses: EpisodeAdAnalysisStore(
                client: UnusedEpisodeAdAnalysisClient(),
                fileStore: adAnalysisFileStore
            ),
            transcriptAnalyses: transcriptAnalyses,
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        let episodeID = try seedAllData(
            fileStore: fileStore,
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            context: context
        ).episodeID
        let producer = FakeChaptersSummaryProducer()
        producer.holdsRuns = true
        producer.attach(to: transcriptAnalyses)
        await appModel.library.load(modelContext: context)
        await appModel.downloads.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        appModel.transcriptAnalyses.load(modelContext: context)

        // The first explicit run parks inside the producer; the second
        // queues behind it, leaving a suspended drain holding a pending
        // episode when the nuke starts. Wait for the producer call itself:
        // the run reports isRunning before it reaches the producer, and a
        // nuke that lands in that gap cancels a run that never started.
        appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: context)
        try #require(await waitUntil {
            transcriptAnalyses.isRunning(for: episodeID) && producer.isHolding
        })
        appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: context)

        try await appModel.nukeAllData(modelContext: context)

        // Cancelling the active job wakes the suspended drain; it must not
        // dequeue the pending episode and start a fresh analysis mid-nuke.
        #expect(producer.requests.count == 1)
        #expect(producer.cancelledRunIDs.count == 1)
        #expect(!transcriptAnalyses.hasActiveJob)
        #expect(transcriptAnalyses.records.isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptAnalysisRecord>()).isEmpty)
    }

    @Test("Nuke resets the Chapters & Summary disclosure acknowledgement")
    func nukeResetsGenerateDisclosureAcknowledgement() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let cacheController = OpenCastCacheController(
            rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: ScriptedTranscriptAnalysisDrainClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
        )
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: cacheController,
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: fileStore),
            transcriptions: EpisodeTranscriptionStore(
                fileStore: EpisodeTranscriptFileStore(baseDirectory: fileStore.baseDirectory)
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                client: UnusedEpisodeAdAnalysisClient(),
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
            ),
            transcriptAnalyses: transcriptAnalyses,
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        transcriptAnalyses.load(modelContext: context)
        transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: context)
        #expect(transcriptAnalyses.hasAcknowledgedGenerateDisclosure)

        try await appModel.nukeAllData(modelContext: context)

        // The next generate after a nuke must disclose again: the
        // preference row is gone and the post-nuke reload reflects it.
        #expect(!transcriptAnalyses.hasAcknowledgedGenerateDisclosure)
        #expect(try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).isEmpty)
    }

    @Test("Delete Data leaves no usage behind: a billed run awaiting resume and a run whose usage never saved count nothing afterwards")
    func nukeLeavesNoUsageFromRunJournals() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        let runsDirectory = fileStore.baseDirectory.appending(path: "AnalysisRuns", directoryHint: .isDirectory)
        let runs = AnalysisRunRecordStore(directory: runsDirectory)
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: fileStore),
            transcriptions: EpisodeTranscriptionStore(
                fileStore: EpisodeTranscriptFileStore(baseDirectory: fileStore.baseDirectory)
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                client: UnusedEpisodeAdAnalysisClient(),
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
            ),
            transcriptAnalyses: EpisodeTranscriptAnalysisStore(
                client: ScriptedTranscriptAnalysisDrainClient(),
                fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: fileStore.baseDirectory)
            ),
            analysisRuns: runs,
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        let chaptersPolicy = try #require(AnalysisPolicySnapshot.baked.chaptersSummary(provider: .google))
        let adPolicy = try #require(AnalysisPolicySnapshot.baked.adDetection(provider: .google))
        func directResolution(_ feature: AnalysisFeature, _ policy: AnalysisRoutePolicy) -> AnalysisRouteResolution {
            AnalysisRouteResolution(
                feature: feature,
                route: .direct(provider: .google),
                policy: policy,
                key: AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText),
                resumingRunID: nil,
                trialExchange: nil
            )
        }

        // Usage from earlier runs, which the wipe deletes.
        appModel.analysisUsage.load(modelContext: context)
        #expect(appModel.analysisUsage.record(
            provider: .google,
            feature: .chaptersSummary,
            inputTokens: 1_000,
            outputTokens: 100,
            at: .now,
            runID: "nuke-earlier-run",
            modelContext: context
        ))
        // A billed Chapters & Summary run whose card expired, its record
        // running and awaiting a resume.
        let episodeID = "nuke-interrupted-chapters"
        let interrupted = AnalysisRunRecord(
            feature: .chaptersSummary,
            episodeID: episodeID,
            podcastID: seededFeedURL,
            transcriptFingerprint: "nuke-fingerprint",
            resolution: directResolution(.chaptersSummary, .chaptersSummary(chaptersPolicy)),
            policy: .chaptersSummary(chaptersPolicy)
        )
        try runs.begin(interrupted)
        runs.update(runID: interrupted.id) { record in
            record.inputTokens = 420
            record.outputTokens = 36
        }
        runs.markExpired(runID: interrupted.id)
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: episodeID,
            podcastID: seededFeedURL,
            transcriptFingerprint: "nuke-fingerprint",
            state: .running,
            analysisRelativePath: "EpisodeTranscriptAnalyses/\(episodeID)/nuke-fingerprint.json"
        ))
        try context.save()
        appModel.transcriptAnalyses.load(modelContext: context)
        #expect(appModel.transcriptAnalyses.resumableEpisodeIDs == [episodeID])
        // An ad-detection run that ended in this process with its usage
        // save failed: the next load would count it.
        let unsaved = AnalysisRunRecord(
            feature: .adDetection,
            episodeID: "nuke-unsaved-ads",
            podcastID: seededFeedURL,
            transcriptFingerprint: "nuke-ad-fingerprint",
            resolution: directResolution(.adDetection, .adDetection(adPolicy)),
            policy: .adDetection(adPolicy)
        )
        try runs.begin(unsaved)
        runs.update(runID: unsaved.id) { record in
            record.inputTokens = 900
            record.outputTokens = 80
        }
        runs.finish(
            runID: unsaved.id,
            outcome: .failed(AnalysisFailure(feature: .adDetection, code: .network, status: 502)),
            listenerFailure: nil,
            background: false
        )
        #expect(appModel.analysisUsage.usage(for: .google).monthInputTokens == 1_000)

        try await appModel.nukeAllData(modelContext: context)

        #expect(appModel.analysisUsage.usage(for: .google).monthInputTokens == 0)
        #expect(appModel.analysisUsage.usage(for: .google).monthOutputTokens == 0)
        #expect(appModel.analysisUsage.usage(for: .google).lastRun == nil)
        #expect(try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).allSatisfy { record in
            record.key != AnalysisUsageStore.preferenceKey(for: .google)
        })
        #expect(runs.records(limit: AnalysisRunRecordStore.maximumRecords).isEmpty)
        #expect(try regularFiles(in: runsDirectory).isEmpty)

        // The next launch's loads find nothing to count.
        appModel.adAnalyses.load(modelContext: context)
        appModel.transcriptAnalyses.load(modelContext: context)
        let relaunched = AnalysisUsageStore()
        relaunched.load(modelContext: context)
        #expect(relaunched.usage(for: .google).monthInputTokens == 0)
        #expect(relaunched.usage(for: .google).lastRun == nil)
        #expect(try regularFiles(in: runsDirectory).isEmpty)
    }

    @Test("The row wipe credits the arbiter once, and an empty wipe credits nothing")
    func rowWipeCreditsTheArbiterOnceAndAnEmptyWipeCreditsNothing() async throws {
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
            appAttestSuspension: AppAttestSuspension(),
            cacheController: cacheController,
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available, .available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        _ = try seedAllData(fileStore: fileStore, context: context)
        await appModel.library.load(modelContext: context)
        await appModel.downloads.load(modelContext: context)
        let creditsBeforeNuke = appModel.library.syncedStoreSelfSaveCount

        try await appModel.nukeAllData(modelContext: context)

        #expect(appModel.library.syncedStoreSelfSaveCount == creditsBeforeNuke + 1)
        try expectAllTablesEmpty(context)

        // Nothing synced is left to delete, so the second wipe touches only
        // the local store and posts no synced notification to swallow.
        try await appModel.nukeAllData(modelContext: context)

        #expect(appModel.library.syncedStoreSelfSaveCount == creditsBeforeNuke + 1)
        #expect(appModel.dataNukeCompletionID == 2)
    }

    @Test("A store holding only playlist rows is wiped through the synced-store credit")
    func playlistOnlyStoreIsWipedThroughTheSyncedStoreCredit() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = try makeAvailableAppModel()
        context.insert(PlaylistRecord(playlistID: "nuke-only-playlist", name: "Only Playlist"))
        context.insert(
            PlaylistItemRecord(
                itemID: "nuke-only-item",
                playlistID: "nuke-only-playlist",
                episodeID: "nuke-only-episode",
                podcastID: seededFeedURL,
                sortKey: PlaylistSortKey.last(after: nil),
                episodeTitle: "Only Episode",
                podcastTitle: "Nuke Show"
            )
        )
        context.insert(PlaylistTombstoneRecord(playlistID: "nuke-only-deleted"))
        try context.save()
        await appModel.library.load(modelContext: context)
        let creditsBeforeNuke = appModel.library.syncedStoreSelfSaveCount

        try await appModel.nukeAllData(modelContext: context)

        #expect(appModel.library.syncedStoreSelfSaveCount == creditsBeforeNuke + 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).isEmpty)
    }

    @Test("The nuke marks the local playlist copy done and drops a pending copy, so a copy that had not finished is not retried")
    func nukeMarksThePlaylistCopyDoneAndDropsThePendingCopy() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let suiteName = "data-nuke-playlist-copy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacySnapshot = LegacyLocalPlaylistSnapshot(
            playlists: [
                LegacyLocalPlaylistSnapshot.Playlist(
                    playlistID: "nuke-legacy-playlist",
                    name: "Legacy Playlist",
                    kindRawValue: "manual",
                    hidesPlayed: false,
                    originRawValue: "user",
                    createdAt: Date(timeIntervalSinceReferenceDate: 813_000_000),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 813_000_000)
                )
            ]
        )
        // The flag is unset and the snapshot still pending: the state a launch
        // whose copy failed (or never ran) is in when Delete Data runs.
        let appModel = try makeAvailableAppModel(
            legacyLocalPlaylists: legacySnapshot,
            playlistMigrationDefaults: defaults
        )
        context.insert(PlaylistRecord(playlistID: "nuke-synced-playlist", name: "Synced Playlist"))
        try context.save()
        await appModel.library.load(modelContext: context)

        try await appModel.nukeAllData(modelContext: context)

        #expect(defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey))
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)

        // Neither the pending snapshot on the next core load nor a fresh
        // launch's copy brings the legacy playlist back.
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(appModel.lastPlaylistError == nil)
        let inserted = try PlaylistLocalStoreMigration.apply(
            legacySnapshot,
            modelContext: context,
            defaults: defaults,
            save: appModel.library.saveSyncedStore
        )
        #expect(inserted == 0)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
    }

    private func makeAvailableAppModel(
        legacyLocalPlaylists: LegacyLocalPlaylistSnapshot? = nil,
        playlistMigrationDefaults: UserDefaults = .standard
    ) throws -> OpenCastAppModel {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(
            baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        )
        return OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available, .available])
            ),
            allowsAutomaticFeedRefresh: false,
            legacyLocalPlaylists: legacyLocalPlaylists,
            playlistMigrationDefaults: playlistMigrationDefaults
        )
    }

    @Test("Refresh finishing after nuke cannot recreate cache rows")
    func refreshFinishingAfterNukeCannotRecreateCacheRows() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/race.xml"
        let feedService = HangingFeedService()
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(feedService: feedService, localCache: localCache),
            downloads: DownloadStore(
                fileStore: EpisodeDownloadFileStore(
                    baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
                )
            ),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Race Show"))
        try context.save()
        await appModel.library.load(modelContext: context)

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

        try await expectAllTablesEmpty(context, localCache: localCache, activeFeedURL: feedURL)
        #expect(appModel.library.episodes.isEmpty)
        #expect(appModel.library.refreshLogs.isEmpty)
    }

    /// The stale refresh here is parked INSIDE its cache write (the gate
    /// below), not at the fetch: that is the one suspension after which the
    /// unwinding flow sweeps the feed cache, and the sweep must not take a
    /// subscription the user re-added after the reset (2026-09-04 review).
    @Test("Stale refresh unwinding after nuke keeps a resubscribed feed's cache")
    func staleRefreshUnwindingAfterNukeKeepsResubscribedFeedCache() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/race-resubscribe.xml"
        let feedService = HangingFeedService()
        let baseCache = SQLiteLocalLibraryCacheStore.inMemory()
        let localCache = GatedLocalLibraryCacheStore(base: baseCache)
        let temporaryDirectory = try makeTemporaryDirectory()
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(feedService: feedService, localCache: localCache),
            downloads: DownloadStore(
                fileStore: EpisodeDownloadFileStore(
                    baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
                )
            ),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Race Show"))
        try context.save()
        await appModel.library.load(modelContext: context)

        let refreshTask = Task { @MainActor in
            await appModel.library.refresh(feedURL: feedURL, modelContext: context)
        }
        #expect(await feedService.waitForRequest())
        await feedService.release(
            makeSnapshot(
                feedURL: feedURL,
                podcastTitle: "Race Show Stale",
                episodeID: "race-stale-episode"
            )
        )
        #expect(await localCache.waitForGatedUpsert())

        try await appModel.nukeAllData(modelContext: context)

        // The user subscribes to the same feed again after the reset.
        await feedService.serveImmediately(
            makeSnapshot(
                feedURL: feedURL,
                podcastTitle: "Race Show Resubscribed",
                episodeID: "race-resubscribed-episode"
            )
        )
        try await appModel.library.subscribe(to: feedURL, modelContext: context)
        let resubscribed = try await baseCache.loadLibrary(activePodcastIDs: [feedURL])
        #expect(resubscribed.episodes.map(\.episodeID) == ["race-resubscribed-episode"])

        // The stale refresh resumes, fails its generation check, and must
        // not sweep the cache the new subscription now owns.
        await localCache.releaseGatedUpsert()
        await refreshTask.value

        let survived = try await baseCache.loadLibrary(activePodcastIDs: [feedURL])
        #expect(survived.podcastsByFeedURL[feedURL] != nil)
        #expect(survived.episodes.contains { $0.episodeID == "race-resubscribed-episode" })
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.map(\.feedURL) == [feedURL])
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
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: cacheController,
            library: LibraryStore(localCache: localCache),
            downloads: DownloadStore(fileStore: fileStore),
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )
        _ = try seedAllData(fileStore: fileStore, context: context)
        try FileManager.default.removeItem(at: cacheController.artworkCacheDirectory)
        try Data("not a directory".utf8).write(to: cacheController.artworkCacheDirectory, options: .atomic)

        await appModel.library.load(modelContext: context)
        await appModel.downloads.load(modelContext: context)
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
        try await expectAllTablesEmpty(context, localCache: localCache, activeFeedURL: seededFeedURL)
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

    @Test("A failing model delete surfaces the nuke error without stranding deleting")
    func failingModelDeleteSurfacesNukeErrorWithoutStrandingDeleting() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptionModels = TranscriptionModelStore(
            installer: ThrowingDeleteTranscriptionModelInstaller()
        )
        transcriptionModels.loadLocalStatus()
        let appModel = OpenCastAppModel(
            appAttestSuspension: AppAttestSuspension(),
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(
                fileStore: EpisodeDownloadFileStore(
                    baseDirectory: temporaryDirectory.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
                )
            ),
            transcriptionModels: transcriptionModels,
            syncStatus: SyncStatusStore(
                accountStatusProvider: SequencedCloudKitAccountStatusProvider(statuses: [.available])
            ),
            allowsAutomaticFeedRefresh: false
        )

        await #expect(throws: (any Error).self) {
            try await appModel.nukeAllData(modelContext: context)
        }

        #expect(appModel.lastDataNukeErrorMessage != nil)
        guard case .failed = transcriptionModels.state else {
            Issue.record("Expected failed model state, got \(transcriptionModels.state)")
            return
        }
        #expect(!appModel.isNukingData)
    }

    private func seedAllData(
        fileStore: EpisodeDownloadFileStore,
        transcriptFileStore: EpisodeTranscriptFileStore? = nil,
        adAnalysisFileStore: EpisodeAdAnalysisFileStore? = nil,
        context: ModelContext
    ) throws -> EpisodeCacheRecord {
        let feedURL = seededFeedURL
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
        context.insert(
            UpNextQueueItemRecord(
                episodeID: episode.episodeID,
                podcastID: feedURL,
                sequence: 0
            )
        )
        context.insert(PlaylistRecord(playlistID: "nuke-playlist", name: "Nuke Playlist"))
        context.insert(
            PlaylistItemRecord(
                itemID: "nuke-playlist-item",
                playlistID: "nuke-playlist",
                episodeID: episode.episodeID,
                podcastID: feedURL,
                sortKey: PlaylistSortKey.last(after: nil),
                episodeTitle: episode.title,
                podcastTitle: "Nuke Show"
            )
        )
        context.insert(PlaylistTombstoneRecord(playlistID: "nuke-deleted-playlist"))
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
        if let transcriptFileStore, let adAnalysisFileStore {
            try seedTranscriptAndAdAnalysis(
                episode: episode,
                sourceAudioURL: sourceAudioURL,
                transcriptFileStore: transcriptFileStore,
                adAnalysisFileStore: adAnalysisFileStore,
                context: context
            )
        }
        context.insert(EpisodeNoteRecord(episodeID: episode.episodeID, timestamp: 12, text: "Moment"))
        let wholeNote = EpisodeNoteRecord(episodeID: episode.episodeID, timestamp: 0, text: "Episode")
        wholeNote.isEpisodeWide = true
        context.insert(wholeNote)
        try context.save()
        return episode
    }

    private func expectAllTablesEmpty(_ context: ModelContext) throws {
        #expect(try context.fetchCount(FetchDescriptor<EpisodeNoteRecord>()) == 0)
        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PodcastCacheRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeCacheRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RefreshLogRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptAnalysisRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<UpNextQueueItemRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>()).isEmpty)
    }

    private func seedTranscriptAndAdAnalysis(
        episode: EpisodeCacheRecord,
        sourceAudioURL: URL,
        transcriptFileStore: EpisodeTranscriptFileStore,
        adAnalysisFileStore: EpisodeAdAnalysisFileStore,
        context: ModelContext
    ) throws {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 8,
                text: "Welcome to the data nuke fixture.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 8,
                end: 16,
                text: "This part is brought to you by Nuke Sponsor.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        let transcriptDocument = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceAudioURL.absoluteString,
            sourceFileByteCount: 16,
            sourceFileSHA256: "nuke-audio-sha",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: 16,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
        let transcriptFingerprint = transcriptFileStore.fingerprint(
            sourceFileSHA256: transcriptDocument.sourceFileSHA256,
            modelIdentifier: transcriptDocument.modelIdentifier,
            modelVersion: transcriptDocument.modelVersion,
            modelTreeSHA256: transcriptDocument.modelTreeSHA256
        )
        let transcriptRelativePath = transcriptFileStore.relativePath(
            episodeID: transcriptDocument.episodeID,
            fingerprint: transcriptFingerprint
        )
        try transcriptFileStore.write(transcriptDocument, relativePath: transcriptRelativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: transcriptDocument.episodeID,
            podcastID: transcriptDocument.podcastID,
            sourceAudioURL: transcriptDocument.sourceAudioURL,
            sourceFileByteCount: transcriptDocument.sourceFileByteCount,
            sourceFileSHA256: transcriptDocument.sourceFileSHA256,
            modelIdentifier: transcriptDocument.modelIdentifier,
            modelVersion: transcriptDocument.modelVersion,
            modelTreeSHA256: transcriptDocument.modelTreeSHA256,
            languageCode: transcriptDocument.languageCode,
            state: .completed,
            audioDuration: transcriptDocument.audioDuration,
            completedDuration: transcriptDocument.audioDuration,
            checkpointCount: transcriptDocument.checkpoints.count,
            transcriptRelativePath: transcriptRelativePath,
            createdAt: transcriptDocument.createdAt,
            updatedAt: transcriptDocument.updatedAt
        ))

        let analysisFingerprint = adAnalysisFileStore.transcriptFingerprint(for: transcriptDocument)
        let analysisRelativePath = adAnalysisFileStore.relativePath(
            episodeID: transcriptDocument.episodeID,
            transcriptFingerprint: analysisFingerprint
        )
        let analysisDocument = EpisodeAdAnalysisDocument(
            schemaVersion: 1,
            episodeID: transcriptDocument.episodeID,
            podcastID: transcriptDocument.podcastID,
            requestID: "nuke-analysis",
            transcriptFingerprint: analysisFingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: transcriptDocument.segments.count,
            model: "gemini-2.5-flash-lite",
            policy: "ads_only",
            spans: [
                EpisodeAdAnalysisSpan(
                    id: 0,
                    kind: .hostReadAd,
                    label: "Nuke Sponsor",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 8,
                    endTime: 16,
                    confidence: 0.95,
                    evidenceQuote: "brought to you"
                )
            ],
            warnings: [],
            usage: EpisodeAdAnalysisUsage(
                promptTokenCount: 10,
                candidatesTokenCount: 4,
                totalTokenCount: 14
            ),
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        try adAnalysisFileStore.write(analysisDocument, relativePath: analysisRelativePath)
        context.insert(EpisodeAdAnalysisRecord(
            episodeID: transcriptDocument.episodeID,
            podcastID: transcriptDocument.podcastID,
            transcriptFingerprint: analysisFingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: transcriptDocument.segments.count,
            state: .completed,
            analysisRelativePath: analysisRelativePath,
            model: analysisDocument.model,
            policy: analysisDocument.policy,
            spanCount: analysisDocument.spans.count,
            warningCount: analysisDocument.warnings.count,
            createdAt: updatedAt,
            updatedAt: updatedAt
        ))
    }

    private func expectAllTablesEmpty(
        _ context: ModelContext,
        localCache: any LocalLibraryCacheStore,
        activeFeedURL: String
    ) async throws {
        try expectAllTablesEmpty(context)
        let cacheSnapshot = try await localCache.loadLibrary(activePodcastIDs: [activeFeedURL])
        #expect(cacheSnapshot.episodes.isEmpty)
        #expect(cacheSnapshot.podcastsByFeedURL.isEmpty)
        #expect(cacheSnapshot.refreshLogs.isEmpty)
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
    private var immediateSnapshot: FeedSnapshot?

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        if let immediateSnapshot {
            return immediateSnapshot
        }
        didRequest = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ snapshot: FeedSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }

    /// Every later fetch (a resubscribe after the reset) returns this at once.
    func serveImmediately(_ snapshot: FeedSnapshot) {
        immediateSnapshot = snapshot
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

/// Parks the first cache upsert until released — the only way to leave a
/// write flow suspended between its cache write and the generation check
/// that follows it. Everything else forwards to the wrapped store.
private actor GatedLocalLibraryCacheStore: LocalLibraryCacheStore {
    private let base: any LocalLibraryCacheStore
    private var gateArmed = true
    private var didGate = false
    private var gate: CheckedContinuation<Void, Never>?

    init(base: any LocalLibraryCacheStore) {
        self.base = base
    }

    func waitForGatedUpsert() async -> Bool {
        for _ in 0..<6_000 {
            if didGate {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return didGate
    }

    func releaseGatedUpsert() {
        gate?.resume()
        gate = nil
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {
        if gateArmed {
            gateArmed = false
            didGate = true
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        try await base.upsertCache(from: snapshot, refreshedAt: refreshedAt)
    }

    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        try await base.loadLibrary(activePodcastIDs: activePodcastIDs)
    }

    func allRefreshLogs() async throws -> [RefreshLogSnapshot] {
        try await base.allRefreshLogs()
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        try await base.episodeDetail(episodeID: episodeID)
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        try await base.showNotesHTMLByEpisodeID(activePodcastIDs: activePodcastIDs)
    }

    func prepareEpisodeSearchIndex() async throws {
        try await base.prepareEpisodeSearchIndex()
    }

    func setEpisodeSearchIndexRebuildHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) async {
        await base.setEpisodeSearchIndexRebuildHandler(handler)
    }

    func searchEpisodes(_ request: EpisodeSearchIndexRequest) async throws -> [EpisodeSearchIndexHit] {
        try await base.searchEpisodes(request)
    }

    func replaceEpisodeTranscriptSearchDocument(_ document: EpisodeSearchTranscriptDocument) async throws {
        try await base.replaceEpisodeTranscriptSearchDocument(document)
    }

    func removeEpisodeTranscriptSearchDocument(episodeID: String) async throws {
        try await base.removeEpisodeTranscriptSearchDocument(episodeID: episodeID)
    }

    func reconcileEpisodeTranscriptSearchDocuments(retaining episodeIDs: Set<String>) async throws {
        try await base.reconcileEpisodeTranscriptSearchDocuments(retaining: episodeIDs)
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {
        try await base.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
    }

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {
        try await base.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
    }

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {
        try await base.insertRefreshLog(log, prunedTo: retentionLimit)
    }

    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators? {
        try await base.feedValidators(forPodcastID: podcastID)
    }

    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws {
        try await base.updateFeedValidators(validators, forPodcastID: podcastID)
    }

    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot] {
        try await base.cachedEpisodes(forPodcastID: podcastID)
    }

    func deleteEpisodes(episodeIDs: [String]) async throws {
        try await base.deleteEpisodes(episodeIDs: episodeIDs)
    }

    func deleteCache(forPodcastID podcastID: String) async throws {
        try await base.deleteCache(forPodcastID: podcastID)
    }

    func deleteAllLocalCache() async throws {
        try await base.deleteAllLocalCache()
    }

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws {
        try await base.replaceNotificationFeedHealth(records)
    }

    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth] {
        try await base.notificationFeedHealthByFeedURL()
    }

    func hasCompletedLegacyImport() async throws -> Bool {
        try await base.hasCompletedLegacyImport()
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {
        try await base.importLegacyCache(podcasts: podcasts, episodes: episodes, refreshLogs: refreshLogs)
    }
}

private final class UnusedEpisodeAdAnalysisClient: EpisodeAdAnalysisClient, @unchecked Sendable {
    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }
}

private final class DataNukeAdFreePassScheduler: AdFreePassContinuedTaskScheduling {
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

private final class ThrowingDeleteTranscriptionModelInstaller: TranscriptionModelInstalling, @unchecked Sendable {
    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        OpenCastWhisperModelInstalledSummary(
            modelIdentifier: model.rawValue,
            version: version,
            totalByteCount: 10,
            treeSHA256: String(repeating: "a", count: 64)
        )
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(schemaVersion: 1, generatedAt: "2026-06-29T00:00:00Z", models: [])
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        throw CocoaError(.featureUnsupported)
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
