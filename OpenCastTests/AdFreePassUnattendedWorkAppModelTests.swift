import Foundation
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// The app model's glue for unattended queue work, without a real player:
/// the playback state comes in through the policy's input.
@MainActor
@Suite("Ad-free pass unattended work in the app model")
struct AdFreePassUnattendedWorkAppModelTests {
    @Test(
        "Scene exit leaves the queue's own unattended transcription running while the rule allows it, and holds it otherwise",
        arguments: SceneExitCase.allCases
    )
    func sceneExitFollowsTheRule(exit: SceneExitCase) async throws {
        let fixture = try await makeFixture(episodeID: "scene-exit-\(exit)")
        fixture.enqueue(origin: .auto)
        #expect(await waitUntil { fixture.transcriber.requestCount == 1 })
        #expect(fixture.appModel.adFreePass.ownsUnattendedActiveTranscription)

        let foreground = UUID()
        let background = UUID()
        fixture.appModel.setAutoDownloadsScene(foreground, isActive: exit == .otherSceneActive)
        // The window that left reports last.
        fixture.appModel.setAutoDownloadsScene(background, isActive: false)
        fixture.appModel.isSceneActive = false
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = exit.playbackState
        fixture.appModel.isLowPowerModeEnabled = { exit == .playingInLowPowerMode }

        fixture.appModel.interruptActiveTranscriptionForLifecycleExit(modelContext: fixture.context)

        if exit.keepsRunning {
            #expect(fixture.appModel.transcriptions.hasActiveJob)
            fixture.transcriber.finishHeldRun()
            #expect(await fixture.waitForDrain())
            #expect(fixture.appModel.adFreePass.drainOutcomes.map(\.kind) == [.completed(zoneCount: 0)])
            #expect(fixture.transcriber.requestCount == 1)
            return
        }

        #expect(await waitUntil { fixture.appModel.adFreePass.queueState == .pausedInterrupted })
        #expect(fixture.appModel.adFreePass.isHoldingUnattendedItem)
        #expect(fixture.appModel.adFreePass.queueItems.map(\.episodeID) == [fixture.episode.episodeID])
        #expect(
            fixture.appModel.transcriptions.record(for: fixture.episode.episodeID)?.errorMessage
                == EpisodeTranscriptionStore.environmentalInterruptMessage
        )
        // No notification for a hold, though the scene is not active.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.notificationCenter.addedRequests.isEmpty)

        // The app comes back: the existing activation path resumes it.
        fixture.appModel.setAutoDownloadsScene(foreground, isActive: true)
        fixture.appModel.isSceneActive = true
        fixture.appModel.resumeEnvironmentalAdFreePassIfNeeded(modelContext: fixture.context)
        #expect(await fixture.waitForDrain())
        #expect(fixture.appModel.adFreePass.drainOutcomes.map(\.kind) == [.completed(zoneCount: 0)])
    }

    @Test("Scene exit gives a manual item's transcription the plain interrupt, as before")
    func sceneExitInterruptsManualItemPlainly() async throws {
        let fixture = try await makeFixture(episodeID: "scene-exit-manual")
        fixture.enqueue(origin: .manual)
        #expect(await waitUntil { fixture.transcriber.requestCount == 1 })
        fixture.appModel.setAutoDownloadsScene(UUID(), isActive: false)
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .playing

        fixture.appModel.interruptActiveTranscriptionForLifecycleExit(modelContext: fixture.context)

        #expect(await waitUntil {
            fixture.appModel.adFreePass.queueState == .idle && !fixture.appModel.transcriptions.hasActiveJob
        })
        #expect(fixture.appModel.adFreePass.queueItems.isEmpty)
        #expect(!fixture.appModel.adFreePass.isQueuePausedForEnvironmentalInterrupt)
        let record = try #require(fixture.appModel.transcriptions.record(for: fixture.episode.episodeID))
        #expect(record.state == .interrupted)
        #expect(record.errorMessage == nil)
    }

    @Test("Playback that stops with no scene active holds after the grace, unless it plays again first, and playing again resumes")
    func playbackStopHoldsAfterTheGraceAndPlayResumes() async throws {
        let fixture = try await makeFixture(episodeID: "playback-stop")
        fixture.enqueue(origin: .auto)
        #expect(await waitUntil { fixture.transcriber.requestCount == 1 })
        fixture.appModel.setAutoDownloadsScene(UUID(), isActive: false)
        fixture.appModel.isSceneActive = false
        var graces: [Duration] = []

        // An Up Next advance: paused, then loading, then playing again
        // before the grace ends.
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .paused
        await fixture.appModel.reactToPlaybackChangeForUnattendedQueueWork(modelContext: fixture.context) { grace in
            graces.append(grace)
            fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .playing
        }
        #expect(graces == [AdFreePassLifecycleInterruptionPolicy.inactiveInterruptionDelay])
        #expect(fixture.appModel.transcriptions.hasActiveJob)
        #expect(fixture.appModel.adFreePass.queueState == .running)
        // Live playback is not background protection: that follows the card only.
        #expect(!fixture.appModel.adFreePass.isBackgroundProtected())

        // A real stop.
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .paused
        await fixture.appModel.reactToPlaybackChangeForUnattendedQueueWork(modelContext: fixture.context) { _ in }
        #expect(await waitUntil { fixture.appModel.adFreePass.queueState == .pausedInterrupted })
        #expect(fixture.appModel.adFreePass.isHoldingUnattendedItem)

        // Played again in Low Power Mode: still held.
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .playing
        fixture.appModel.isLowPowerModeEnabled = { true }
        await fixture.appModel.reactToPlaybackChangeForUnattendedQueueWork(modelContext: fixture.context) { _ in }
        #expect(fixture.appModel.adFreePass.queueState == .pausedInterrupted)

        fixture.appModel.isLowPowerModeEnabled = { false }
        await fixture.appModel.reactToPlaybackChangeForUnattendedQueueWork(modelContext: fixture.context) { _ in }
        #expect(await fixture.waitForDrain())
        #expect(fixture.appModel.adFreePass.drainOutcomes.map(\.kind) == [.completed(zoneCount: 0)])
        #expect(fixture.transcriber.requestCount == 2)
    }

    @Test("A card expiration gives an unattended item the plain interrupt, as before")
    func cardExpirationInterruptsUnattendedItemPlainly() async throws {
        let fixture = try await makeFixture(episodeID: "card-expiry")
        fixture.appModel.configureBackgroundSessionExpirations(modelContext: fixture.context)
        fixture.enqueue(origin: .auto)
        #expect(await waitUntil { fixture.transcriber.requestCount == 1 })
        fixture.appModel.armBackgroundContinuationForActiveQueue()
        #expect(fixture.appModel.adFreePassBackgroundSession.isArmed)
        let handle = FakeAdFreePassContinuedTaskHandle()
        fixture.scheduler.launch(handle)
        fixture.appModel.setAutoDownloadsScene(UUID(), isActive: false)
        fixture.appModel.isSceneActive = false

        handle.expire()

        #expect(await waitUntil {
            fixture.appModel.adFreePass.queueState == .idle && !fixture.appModel.transcriptions.hasActiveJob
        })
        #expect(fixture.appModel.adFreePass.queueItems.isEmpty)
        #expect(!fixture.appModel.adFreePass.isQueuePausedForEnvironmentalInterrupt)
        let record = try #require(fixture.appModel.transcriptions.record(for: fixture.episode.episodeID))
        #expect(record.state == .interrupted)
        #expect(record.errorMessage == nil)
    }

    @Test("A hold that ends an armed card still posts the paused notification, which answers the system's banner")
    func holdUnderAnArmedCardStillNotifies() async throws {
        let fixture = try await makeFixture(episodeID: "hold-under-card")
        fixture.enqueue(origin: .auto)
        #expect(await waitUntil { fixture.transcriber.requestCount == 1 })
        fixture.appModel.armBackgroundContinuationForActiveQueue()
        #expect(fixture.appModel.adFreePassBackgroundSession.isArmed)
        let handle = FakeAdFreePassContinuedTaskHandle()
        fixture.scheduler.launch(handle)
        fixture.appModel.setAutoDownloadsScene(UUID(), isActive: false)
        fixture.appModel.isSceneActive = false
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .paused

        fixture.appModel.adFreePass.holdActiveItemForLifecycle(modelContext: fixture.context)

        #expect(await waitUntil { fixture.appModel.adFreePass.queueState == .pausedInterrupted })
        #expect(fixture.appModel.adFreePass.isHoldingUnattendedItem)
        #expect(await waitUntil { fixture.notificationCenter.addedRequests.count == 1 })
        #expect(fixture.notificationCenter.addedRequests.first?.content.title == "Ad detection paused")
    }

    @Test("Playback that plays on in Low Power Mode with no scene active holds after the grace")
    func playbackInLowPowerModeHoldsAfterTheGrace() async throws {
        let fixture = try await makeFixture(episodeID: "playback-low-power")
        fixture.enqueue(origin: .auto)
        #expect(await waitUntil { fixture.transcriber.requestCount == 1 })
        fixture.appModel.setAutoDownloadsScene(UUID(), isActive: false)
        fixture.appModel.isSceneActive = false
        fixture.appModel.unattendedQueueWorkPlaybackStateOverride = .playing
        fixture.appModel.isLowPowerModeEnabled = { true }
        var graces: [Duration] = []

        await fixture.appModel.reactToPlaybackChangeForUnattendedQueueWork(modelContext: fixture.context) { grace in
            graces.append(grace)
        }

        #expect(graces == [AdFreePassLifecycleInterruptionPolicy.inactiveInterruptionDelay])
        #expect(await waitUntil { fixture.appModel.adFreePass.queueState == .pausedInterrupted })
        #expect(fixture.appModel.adFreePass.isHoldingUnattendedItem)
        #expect(fixture.appModel.adFreePass.queueItems.map(\.episodeID) == [fixture.episode.episodeID])
        #expect(fixture.transcriber.requestCount == 1)
    }

    @Test("The playback observer's task is cancelled when the app model goes away")
    func playbackObserverIsCancelledAtTeardown() async throws {
        var fixture: Fixture? = try await makeFixture(episodeID: "observer-teardown")
        weak let appModel = fixture?.appModel
        let context = try #require(fixture?.context)
        fixture?.appModel.startUnattendedQueueWorkObservation(modelContext: context)
        let task = try #require(fixture?.appModel.unattendedQueueWorkObservationTask)
        // Let the loop reach its wait for the next playback change.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!task.isCancelled)

        fixture = nil

        #expect(appModel == nil)
        #expect(task.isCancelled)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let appModel: OpenCastAppModel
        let context: ModelContext
        let episode: EpisodeListItemSnapshot
        let transcriber: FirstRunHoldingTranscriber
        let scheduler: FakeAdFreePassContinuedTaskScheduler
        let notificationCenter: FakeAdFreePassNotificationCenter

        func enqueue(origin: AdFreePassQueueOrigin) {
            appModel.adFreePass.enqueue(
                episode: episode,
                origin: origin,
                downloads: appModel.downloads,
                transcriptionModels: appModel.transcriptionModels,
                appleSpeechAssets: appModel.appleSpeechAssets,
                transcriptions: appModel.transcriptions,
                adAnalyses: appModel.adAnalyses,
                modelContext: context,
                refreshSkipZones: { 0 }
            )
        }

        func waitForDrain() async -> Bool {
            await waitUntil {
                appModel.adFreePass.queueState == .idle
                    && appModel.adFreePass.activeEpisodeID == nil
                    && appModel.adFreePass.drainOutcomes.count == 1
            }
        }
    }

    private func makeFixture(episodeID: String) async throws -> Fixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastUnattendedWorkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let downloads = DownloadStore(fileStore: downloadFileStore)
        let transcriptionModels = TranscriptionModelStore(installer: UnattendedWorkModelInstaller())
        let transcriber = FirstRunHoldingTranscriber(heldRunCount: 1)
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: directory)
        )
        let adAnalyses = EpisodeAdAnalysisStore(
            client: UnpolledAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            runEnvironment: ScriptedAdAnalysisRunEnvironment()
        )
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let notificationCenter = FakeAdFreePassNotificationCenter()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: AppleSpeechAssetStore(
                provider: FakeAppleSpeechAssetProvider(isTranscriberAvailable: false),
                userDefaults: UserDefaults(suiteName: "unattended-work-\(UUID().uuidString)") ?? .standard
            ),
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession(scheduler: scheduler),
            transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession(
                scheduler: FakeAdFreePassContinuedTaskScheduler()
            ),
            allowsAutomaticFeedRefresh: false,
            adFreePassNotificationCenter: notificationCenter
        )
        appModel.isLowPowerModeEnabled = { false }

        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: episodeID,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
        let sourceURL = try #require(URL(string: episode.audioURL ?? ""))
        let relativePath = downloadFileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
        try downloadFileStore.prepareDownloadsDirectory()
        let data = Data("downloaded \(episodeID)".utf8)
        try data.write(to: downloadFileStore.fileURL(relativePath: relativePath), options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        )
        record.sourceFileSHA256 = OpenCastSHA256.hash(data)
        context.insert(record)
        try context.save()
        await downloads.load(modelContext: context)
        transcriptionModels.load(modelContext: context)
        transcriptions.load(modelContext: context)
        adAnalyses.load(modelContext: context)

        return Fixture(
            appModel: appModel,
            context: context,
            episode: episode,
            transcriber: transcriber,
            scheduler: scheduler,
            notificationCenter: notificationCenter
        )
    }
}

/// How the app stands when its last scene leaves while the queue's own
/// unattended transcription runs.
enum SceneExitCase: CaseIterable, Sendable {
    case otherSceneActive
    case playingOnFullPower
    case playingInLowPowerMode
    case paused
    case idle

    var playbackState: PlaybackState {
        switch self {
        case .otherSceneActive, .idle: .idle
        case .playingOnFullPower, .playingInLowPowerMode: .playing
        case .paused: .paused
        }
    }

    var keepsRunning: Bool {
        switch self {
        case .otherSceneActive, .playingOnFullPower: true
        case .playingInLowPowerMode, .paused, .idle: false
        }
    }
}

private final class UnattendedWorkModelInstaller: TranscriptionModelInstalling, @unchecked Sendable {
    private let summary = OpenCastWhisperModelInstalledSummary(
        modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
        version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
        totalByteCount: 10,
        treeSHA256: String(repeating: "d", count: 64)
    )

    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        summary
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(schemaVersion: 1, generatedAt: "2026-11-15T00:00:00Z", models: [])
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        summary
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
    }
}
