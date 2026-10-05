import CryptoKit
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// Transcribe Remotely under its own continued-processing card. Only a
/// user's start or resume arms it, after the episode is reserved and the
/// run exists; launch and activation re-attach stay foreground-only.
/// Expiration parks the same job without a `/cancel`, one card serves the
/// whole app in every ordering, and the remote card never counts as local
/// lifecycle protection.
@MainActor
@Suite("Remote transcription continued processing", .serialized)
struct RemoteTranscriptionContinuationTests {
    @MainActor
    private struct Device {
        let api: RemoteJobFaultInjectingAPI
        let defaults: UserDefaults
        let diagnostics: RecordingRemoteJobDiagnosticSink
        let downloads: DownloadStore
        let transcriptions: EpisodeTranscriptionStore
        let adAnalyses: EpisodeAdAnalysisStore
        let context: ModelContext
        let episodes: [EpisodeListItemSnapshot]

        /// Persisted state an earlier process wrote, with a throwaway sink.
        var seedStore: RemoteTranscriptionJobStore {
            RemoteTranscriptionJobStore(defaults: defaults, diagnostics: RecordingRemoteJobDiagnosticSink())
        }

        func episode(_ episodeID: String) -> EpisodeListItemSnapshot {
            episodes.first { $0.episodeID == episodeID }!
        }

        func reference(_ episodeID: String) -> RemoteTranscriptionJobReference? {
            seedStore.existingReference(for: episodeID)
        }
    }

    @MainActor
    private struct AppRig {
        let appModel: OpenCastAppModel
        let remoteScheduler: FakeAdFreePassContinuedTaskScheduler
        let adFreeScheduler: FakeAdFreePassContinuedTaskScheduler
        let generateScheduler: FakeAdFreePassContinuedTaskScheduler

        var remoteSession: EpisodeRemoteTranscriptionBackgroundSession {
            appModel.remoteTranscriptionBackgroundSession
        }

        func parkRemote() async {
            appModel.remoteTranscription.park(exit: .parked)
            _ = await waitUntil { appModel.remoteTranscription.store.hasActiveRequest == false }
        }
    }

    enum Card: String, Sendable, CaseIterable {
        case remote
        case adFree
        case generate
    }

    // MARK: Arm only from a user action

    @Test("A user start arms after the reservation and the run exist, and every phase reaches the callback with its episode")
    func userStartPreparesAfterReservationAndRun() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-arm-order"])
        let episode = device.episode("ep-arm-order")
        let coordinator = makeCoordinator(device)
        var published: [(episodeID: String, phase: RemoteTranscriptionRequestPhase)] = []
        coordinator.onPhaseChange = { published.append(($0, $1)) }
        var prepareCount = 0
        var hadActiveRun = false
        var reservedEpisodeConflict: EpisodeTranscriptionWorkCoordinator.Conflict?

        let outcome = coordinator.start(episode: episode, modelContext: device.context) {
            prepareCount += 1
            hadActiveRun = coordinator.store.hasActiveRequest
                && coordinator.store.activeEpisodeID == episode.episodeID
            reservedEpisodeConflict = device.transcriptions.workCoordinator.localStartConflict(
                episodeID: episode.episodeID,
                reservation: nil
            )
        }

        #expect(outcome == .started)
        #expect(prepareCount == 1)
        #expect(hadActiveRun)
        #expect(reservedEpisodeConflict == .remoteTranscriptionForEpisode)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        coordinator.park(exit: .parked)
        #expect(await waitUntil { coordinator.store.phase == .parkedOnServer(.parked) })

        #expect(published.allSatisfy { $0.episodeID == episode.episodeID })
        #expect(published.first?.phase == .preparing)
        #expect(published.contains { $0.phase == .downloadingBoth })
        #expect(published.contains { $0.phase == .verifying })
        #expect(published.last?.phase == .parkedOnServer(.parked))
    }

    @Test("A rejected start, a cancel-pending episode and an episode without audio never arm")
    func rejectedStartsNeverPrepare() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-live", "ep-other", "ep-cancelling"])
        let coordinator = makeCoordinator(device)
        var prepareCount = 0
        let prepare = { prepareCount += 1 }

        #expect(coordinator.start(episode: device.episode("ep-live"), modelContext: device.context, prepareBackgroundSession: prepare) == .started)
        #expect(prepareCount == 1)
        #expect(coordinator.start(episode: device.episode("ep-live"), modelContext: device.context, prepareBackgroundSession: prepare) != .started)
        #expect(coordinator.resume(episode: device.episode("ep-other"), modelContext: device.context, prepareBackgroundSession: prepare) != .started)
        #expect(prepareCount == 1)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        coordinator.park(exit: .parked)
        #expect(await waitUntil { !coordinator.store.hasActiveRequest })
        #expect(await waitUntil { device.transcriptions.workCoordinator.localStartConflict(episodeID: "ep-live", reservation: nil) == nil })

        let seed = coordinator.store
        _ = seed.reference(for: "ep-cancelling")
        seed.recordUserCancelIntent(episodeID: "ep-cancelling")
        #expect(coordinator.start(episode: device.episode("ep-cancelling"), modelContext: device.context, prepareBackgroundSession: prepare) != .started)

        let silent = EpisodeListItemSnapshot.fixture(episodeID: "ep-silent", duration: 120, audioURL: nil, guid: "ep-silent")
        #expect(coordinator.start(episode: silent, modelContext: device.context, prepareBackgroundSession: prepare) == .started)
        #expect(coordinator.store.phase(for: "ep-silent") == .failed(.missingAudio))
        #expect(prepareCount == 1)
    }

    @Test("Confirm and Resume taps arm the remote card without GPU, even where the platform offers it")
    func userTapsArmWithoutGPU() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-tap"])
        let rig = makeAppModel(device)
        rig.remoteScheduler.supportsGPUResources = true

        let outcome = rig.appModel.confirmRemoteTranscriptionStart(
            RemoteTranscriptionStartPreviewRequest(episodeID: "ep-tap", durationSeconds: 120),
            modelContext: device.context
        )
        #expect(outcome == .started(episodeID: "ep-tap"))
        #expect(rig.remoteScheduler.submittedGPUFlags == [false])
        #expect(rig.remoteSession.isArmed)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })

        // A run that ends before its task launched no longer holds the card.
        await rig.parkRemote()
        #expect(!rig.remoteSession.isArmed)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode("ep-tap"), modelContext: device.context) == .started)
        #expect(rig.remoteScheduler.submittedGPUFlags == [false, false])
        #expect(rig.remoteScheduler.registerCallCount == 1)
        #expect(rig.remoteSession.isArmed)
        #expect(device.diagnostics.events(of: .sessionArmed).map(\.episodeID) == ["ep-tap", "ep-tap"])
        #expect(device.diagnostics.events(of: .sessionArmed).allSatisfy {
            $0.component == .backgroundSession && $0.purpose == .transcription
        })
        await rig.parkRemote()
    }

    @Test("Launch and activation re-attach a parked job without ever arming the card")
    func reattachNeverArms() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-reattach"])
        let seeded = seedAttached(device, "ep-reattach")
        let rig = makeAppModel(device)
        rig.appModel.restorePlaybackSurfaceIfNeeded(modelContext: device.context)

        let launch = try #require(rig.appModel.reattachRemoteJobsIfNeeded(modelContext: device.context, trigger: .launch))
        await launch.value
        #expect(await waitUntil { device.api.pollCalls.contains { $0.jobID == "job-seeded-1" } })
        await rig.parkRemote()
        let pollsAtPark = device.api.pollCalls.count

        let activation = try #require(rig.appModel.reattachRemoteJobsIfNeeded(modelContext: device.context, trigger: .sceneActivated))
        await activation.value
        #expect(await waitUntil { device.api.pollCalls.count > pollsAtPark })

        #expect(rig.remoteScheduler.registerCallCount == 0)
        #expect(rig.remoteScheduler.submitCallCount == 0)
        #expect(!rig.remoteSession.isArmed)
        #expect(device.diagnostics.events.allSatisfy { $0.component != .backgroundSession })
        #expect(device.api.createRequests.map(\.clientRequestID) == [seeded.clientRequestID, seeded.clientRequestID])
        #expect(device.api.cancelCalls.isEmpty)
        await rig.parkRemote()
    }

    // MARK: Expiration

    @Test("Expiration parks the job once: lastExit parked, the server-still-working copy, an empty cancel list, and activation resumes the same job")
    func expirationParksOnceWithoutCancel() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-expire"])
        let rig = makeAppModel(device)
        let handle = FakeAdFreePassContinuedTaskHandle()

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode("ep-expire"), modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.remoteScheduler.launch(handle)
        #expect(rig.remoteSession.isRunning)
        handle.expire()
        handle.expire()

        #expect(await waitUntil {
            rig.appModel.remoteTranscription.store.phase(for: "ep-expire") == .parkedOnServer(.parked)
        })
        let reference = try #require(device.reference("ep-expire"))
        #expect(reference.createState == .attached)
        #expect(reference.jobID == "job-fake-1")
        #expect(reference.lastExit == .parked)
        #expect(reference.userCancelRequestedAt == nil)
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.api.serverState(of: "job-fake-1") == .transcribing)
        // The card completes only after the park's run ending and its
        // notification decision have been delivered.
        #expect(await waitUntil { handle.completions == [false] })
        #expect(handle.titleUpdates.last?.subtitle == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(RemoteTranscriptionStatusPresentation.make(
            phase: rig.appModel.remoteTranscription.store.phase(for: "ep-expire")
        )?.offersResume == true)
        #expect(device.diagnostics.events(of: .sessionExpired).count == 1)
        #expect(device.diagnostics.events(of: .parked).count == 1)
        #expect(device.diagnostics.containsInOrder([.sessionArmed, .sessionLaunched, .sessionExpired, .parked, .sessionCompleted]))
        #expect(device.diagnostics.events(of: .sessionExpired).first?.jobID == "job-fake-1")
        #expect(!rig.remoteSession.isArmed)

        let pollsAtPark = device.api.pollCalls.count
        rig.appModel.restorePlaybackSurfaceIfNeeded(modelContext: device.context)
        let activation = try #require(rig.appModel.reattachRemoteJobsIfNeeded(modelContext: device.context, trigger: .sceneActivated))
        await activation.value
        #expect(await waitUntil { device.api.pollCalls.count > pollsAtPark })
        #expect(device.api.mintedJobIDs == ["job-fake-1"])
        #expect(Set(device.api.createRequests.map(\.clientRequestID)) == [reference.clientRequestID])
        #expect(device.api.cancelCalls.isEmpty)
        #expect(rig.remoteScheduler.submitCallCount == 1)
        await rig.parkRemote()
    }

    @Test("A user cancel under a live card sends exactly one cancel and ends the card unsuccessfully")
    func userCancelEndsCardWithOneCancel() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-cancel"])
        let rig = makeAppModel(device)
        let handle = FakeAdFreePassContinuedTaskHandle()

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode("ep-cancel"), modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.remoteScheduler.launch(handle)
        rig.appModel.remoteTranscription.cancel()
        await rig.appModel.remoteTranscription.userCancelTask?.value

        #expect(device.api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(device.reference("ep-cancel") == nil)
        #expect(handle.completions == [false])
        #expect(handle.titleUpdates.last?.subtitle == RemoteTranscriptionRequestPhase.cancelled.displayText)
        #expect(!rig.remoteSession.isArmed)
    }

    @Test("A delivered result fills the card and completes it successfully")
    func deliveredResultCompletesCard() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-deliver"], deliversResult: true)
        let rig = makeAppModel(device)
        let handle = FakeAdFreePassContinuedTaskHandle()

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode("ep-deliver"), modelContext: device.context) == .started)
        rig.remoteScheduler.launch(handle)

        #expect(await waitUntil { rig.appModel.remoteTranscription.store.phase(for: "ep-deliver") == .completed })
        #expect(handle.completions == [true])
        #expect(handle.progress.completedUnitCount == EpisodeRemoteTranscriptionProgressMapper.totalUnitCount)
        #expect(device.reference("ep-deliver") == nil)
        #expect(device.api.cancelCalls.isEmpty)
        let completed = try #require(device.diagnostics.events(of: .sessionCompleted).first)
        #expect(completed.jobID == "job-fake-1")
        #expect(completed.disposition == .cleared)
        #expect(!rig.remoteSession.isArmed)
    }

    // MARK: One card per app

    @Test("A second continued-processing card never arms, in every ordering of the three sessions", arguments: [
        (Card.remote, Card.adFree), (.remote, .generate),
        (.adFree, .remote), (.generate, .remote),
        (.adFree, .generate), (.generate, .adFree),
    ])
    func oneCardInEveryOrdering(first: Card, second: Card) async throws {
        let device = try await makeDevice(episodeIDs: ["ep-card-remote", "ep-card-cloud"])
        let rig = makeAppModel(device)

        await attemptArm(first, rig: rig, device: device)
        #expect(isArmed(first, rig))
        #expect(scheduler(for: first, rig).submitCallCount == 1)

        await attemptArm(second, rig: rig, device: device)
        #expect(!isArmed(second, rig))
        #expect(scheduler(for: second, rig).submitCallCount == 0)
        #expect(isArmed(first, rig))
        switch second {
        case .remote:
            let refused = device.diagnostics.events(of: .sessionForegroundOnly).filter { $0.purpose == .transcription }
            #expect(refused.map(\.episodeID) == ["ep-card-remote"])
        case .adFree:
            let refused = device.diagnostics.events(of: .sessionForegroundOnly).filter { $0.purpose == .adDetection }
            #expect(refused.map(\.episodeID) == ["ep-card-cloud"])
        case .generate:
            break
        }

        rig.appModel.adFreePass.reset()
        if rig.appModel.remoteTranscription.store.hasActiveRequest {
            await rig.parkRemote()
        }
        rig.appModel.transcriptGenerationBackgroundSession.reset()
    }

    @Test("A live remote card never counts as local lifecycle protection")
    func remoteCardDoesNotProtectLocalWork() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-protect"])
        let rig = makeAppModel(device)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode("ep-protect"), modelContext: device.context) == .started)
        rig.remoteScheduler.launch(FakeAdFreePassContinuedTaskHandle())

        #expect(rig.remoteSession.isRunning)
        #expect(!rig.appModel.isProtectingLocalBackgroundWork)
        await rig.parkRemote()
    }

    // MARK: Helpers

    private func attemptArm(_ card: Card, rig: AppRig, device: Device) async {
        switch card {
        case .remote:
            _ = rig.appModel.resumeRemoteTranscription(episode: device.episode("ep-card-remote"), modelContext: device.context)
        case .adFree:
            rig.appModel.startAdFreePass(for: device.episode("ep-card-cloud"), modelContext: device.context, mode: .cloud)
            _ = await waitUntil {
                device.diagnostics.events.contains {
                    $0.component == .backgroundSession
                        && $0.purpose == .adDetection
                        && ($0.kind == .sessionArmed || $0.kind == .sessionForegroundOnly)
                }
            }
        case .generate:
            rig.appModel.armTranscriptGenerationBackgroundSessionIfNeeded(episodeTitle: "Generating")
        }
    }

    private func isArmed(_ card: Card, _ rig: AppRig) -> Bool {
        switch card {
        case .remote: rig.appModel.remoteTranscriptionBackgroundSession.isArmed
        case .adFree: rig.appModel.adFreePassBackgroundSession.isArmed
        case .generate: rig.appModel.transcriptGenerationBackgroundSession.isArmed
        }
    }

    private func scheduler(for card: Card, _ rig: AppRig) -> FakeAdFreePassContinuedTaskScheduler {
        switch card {
        case .remote: rig.remoteScheduler
        case .adFree: rig.adFreeScheduler
        case .generate: rig.generateScheduler
        }
    }

    private func makeAppModel(_ device: Device) -> AppRig {
        let remoteScheduler = FakeAdFreePassContinuedTaskScheduler()
        let adFreeScheduler = FakeAdFreePassContinuedTaskScheduler()
        let generateScheduler = FakeAdFreePassContinuedTaskScheduler()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: device.downloads,
            transcriptions: device.transcriptions,
            adAnalyses: device.adAnalyses,
            remoteTranscriptionAPI: device.api,
            remoteTranscriptionJobStore: RemoteTranscriptionJobStore(
                defaults: device.defaults,
                diagnostics: device.diagnostics
            ),
            adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession(scheduler: adFreeScheduler),
            transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession(scheduler: generateScheduler),
            remoteTranscriptionBackgroundSession: EpisodeRemoteTranscriptionBackgroundSession(scheduler: remoteScheduler),
            allowsAutomaticFeedRefresh: false,
            adFreePassNotificationCenter: FakeAdFreePassNotificationCenter()
        )
        appModel.configureBackgroundSessionExpirations(modelContext: device.context)
        return AppRig(
            appModel: appModel,
            remoteScheduler: remoteScheduler,
            adFreeScheduler: adFreeScheduler,
            generateScheduler: generateScheduler
        )
    }

    private func makeCoordinator(_ device: Device) -> EpisodeRemoteTranscriptionCoordinator {
        EpisodeRemoteTranscriptionCoordinator(
            api: device.api,
            downloads: device.downloads,
            transcriptions: device.transcriptions,
            store: RemoteTranscriptionJobStore(defaults: device.defaults, diagnostics: device.diagnostics),
            transportRetryDelays: [],
            localRetryDelays: []
        )
    }

    @discardableResult
    private func seedAttached(_ device: Device, _ episodeID: String) -> RemoteTranscriptionJobReference {
        let seedStore = device.seedStore
        let minted = seedStore.reference(for: episodeID)
        seedStore.markCreateAttempted(episodeID: episodeID)
        seedStore.attachJob(id: "job-seeded-1", episodeID: episodeID)
        seedStore.recordExit(.parked, episodeID: episodeID)
        device.api.seedServerJob(clientRequestID: minted.clientRequestID, jobID: "job-seeded-1", state: .transcribing)
        return minted
    }

    /// Builds a device whose episodes each have a completed download with a
    /// known source identity, so a run reaches the poll leg. With
    /// `deliversResult`, the server finishes the first episode's job.
    private func makeDevice(
        episodeIDs: [String],
        deliversResult: Bool = false
    ) async throws -> Device {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        try downloadFileStore.prepareDownloadsDirectory()

        var episodes: [EpisodeListItemSnapshot] = []
        var identities: [OpenCastRemoteTranscriptionSourceIdentity] = []
        for episodeID in episodeIDs {
            let episode = EpisodeListItemSnapshot.fixture(
                episodeID: episodeID,
                duration: 120,
                audioURL: "https://example.com/\(episodeID).mp3",
                artworkURL: "https://example.com/art.jpg",
                guid: episodeID
            )
            let sourceURL = URL(string: episode.audioURL!)!
            let relativePath = downloadFileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
            let data = Data("remote audio bytes \(episodeID)".utf8)
            try data.write(to: downloadFileStore.fileURL(relativePath: relativePath), options: .atomic)
            let identity = OpenCastRemoteTranscriptionSourceIdentity(
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                byteCount: Int64(data.count),
                durationSeconds: 120
            )
            let record = EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: episode.podcastID,
                sourceAudioURL: sourceURL.absoluteString,
                localRelativePath: relativePath,
                state: .completed,
                bytesReceived: Int64(data.count),
                bytesExpected: Int64(data.count)
            )
            record.sourceFileSHA256 = identity.sha256
            record.duration = 120
            context.insert(record)
            episodes.append(episode)
            identities.append(identity)
        }
        try context.save()
        await downloads.load(modelContext: context)

        let api = if deliversResult, let identity = identities.first {
            RemoteJobFaultInjectingAPI(
                pollScript: [
                    OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing),
                    OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .resultReady),
                ],
                resultResponse: OpenCastRemoteTranscriptionResultResponse(
                    schemaVersion: 1,
                    result: Self.result(identity: identity, durationSeconds: 120)
                )
            )
        } else {
            RemoteJobFaultInjectingAPI(pollScript: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing),
            ])
        }
        let suiteName = "remote-continuation-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return Device(
            api: api,
            defaults: defaults,
            diagnostics: RecordingRemoteJobDiagnosticSink(),
            downloads: downloads,
            transcriptions: EpisodeTranscriptionStore(
                fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
            ),
            context: context,
            episodes: episodes
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastRemoteContinuationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A result whose words and normalized hash are self-consistent, so it
    /// passes mapper validation against the given identity.
    private static func result(
        identity: OpenCastRemoteTranscriptionSourceIdentity,
        durationSeconds: Double
    ) -> OpenCastRemoteTranscriptionResult {
        let words = [
            OpenCastRemoteTranscriptWord(start: 0.0, end: 0.6, text: "Hello"),
            OpenCastRemoteTranscriptWord(start: 0.6, end: 1.1, text: "remote"),
            OpenCastRemoteTranscriptWord(start: 1.1, end: 1.7, text: "transcript."),
        ]
        let normalized = OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(
            words.map(\.text).joined(separator: " ")
        )
        return OpenCastRemoteTranscriptionResult(
            schemaVersion: 1,
            sourceIdentity: identity,
            languageCode: "en",
            durationSeconds: durationSeconds,
            text: "Hello remote transcript.",
            segments: [
                OpenCastRemoteTranscriptSegment(id: 0, start: 0.0, end: 1.7, text: "Hello remote transcript.", words: words),
            ],
            provenance: OpenCastRemoteTranscriptionModelProvenance(
                provider: "cloudflare-workers-ai",
                modelIdentifier: "@cf/openai/whisper-large-v3-turbo",
                modelRevision: nil,
                servingContractVersion: "1",
                requestSettingsSHA256: String(repeating: "a", count: 64),
                chunkManifestSHA256: String(repeating: "b", count: 64),
                normalizedTranscriptSHA256: normalized,
                pipelineVersion: "stitch-v3"
            ),
            warnings: []
        )
    }
}
