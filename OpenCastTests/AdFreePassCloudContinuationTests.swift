import CryptoKit
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// The cloud ad-detection pass under the ad-free-pass card. Expiration, a
/// lost connection and a failed local request keep the paid server job and
/// park its queue item at the head with a persisted reason, so every queue
/// surface offers Resume on the same job. Removing a parked item is the user
/// cancel: the intent is persisted first, exactly one `/cancel` follows, and
/// the queue record goes only after that attempt.
///
/// A "relaunch" builds a new store, runner, queue and session over the same
/// defaults, model context and fake server.
@MainActor
@Suite("Cloud pass continued processing", .serialized)
struct AdFreePassCloudContinuationTests {
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
            seedStore.existingReference(for: episodeID, purpose: .adDetection)
        }

        func record(_ episodeID: String) throws -> AdFreePassQueueItemRecord? {
            try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).first { $0.episodeID == episodeID }
        }

        func launch(launchPreparationGate: @escaping @Sendable () async -> Void = {}) -> CloudSession {
            let store = RemoteTranscriptionJobStore(defaults: defaults, diagnostics: diagnostics)
            let runner = RemoteTranscriptionJobRunner(
                api: api,
                downloads: downloads,
                transcriptions: transcriptions,
                store: store,
                transportRetryDelays: [],
                localRetryDelays: []
            )
            let scheduler = FakeAdFreePassContinuedTaskScheduler()
            scheduler.supportsGPUResources = true
            let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
            // Wired as the app model wires them.
            let pass = EpisodeAdFreePassCoordinator(launchPreparationGate: launchPreparationGate)
            let terminals = TerminalRecorder()
            pass.onStageChange = { stage, queueContext in
                session.noteStage(stage, queueContext: queueContext)
            }
            pass.onQueueTerminal = { outcome in
                terminals.values.append(outcome)
                session.noteQueueTerminal(outcome)
            }
            return CloudSession(
                device: self,
                store: store,
                runner: runner,
                pass: pass,
                purchases: RemoteTranscriptionPurchaseStore(api: api, storeKit: LiveRemoteTranscriptionStoreKitClient()),
                transcriptionModels: TranscriptionModelStore(),
                appleSpeechAssets: AppleSpeechAssetStore(),
                scheduler: scheduler,
                session: session,
                terminals: terminals
            )
        }
    }

    @MainActor
    private final class TerminalRecorder {
        var values: [AdFreePassQueueTerminalOutcome] = []
    }

    @MainActor
    private struct CloudSession {
        let device: Device
        let store: RemoteTranscriptionJobStore
        let runner: RemoteTranscriptionJobRunner
        let pass: EpisodeAdFreePassCoordinator
        let purchases: RemoteTranscriptionPurchaseStore
        let transcriptionModels: TranscriptionModelStore
        let appleSpeechAssets: AppleSpeechAssetStore
        let scheduler: FakeAdFreePassContinuedTaskScheduler
        let session: EpisodeAdFreePassBackgroundSession
        let terminals: TerminalRecorder

        func restoreQueue() {
            let episodes = device.episodes
            pass.restorePersistedQueue(
                resolveEpisode: { episodeID in episodes.first { $0.episodeID == episodeID } },
                downloads: device.downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: device.transcriptions,
                adAnalyses: device.adAnalyses,
                modelContext: device.context,
                podcastLanguageCode: { _ in nil },
                remoteRunner: runner,
                remoteJobStore: store,
                remotePurchases: purchases,
                refreshSkipZones: { _ in 0 }
            )
        }

        func enqueueCloud(_ episode: EpisodeListItemSnapshot) {
            pass.enqueue(
                episode: episode,
                origin: .manual,
                downloads: device.downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: device.transcriptions,
                adAnalyses: device.adAnalyses,
                modelContext: device.context,
                mode: .cloud,
                remoteRunner: runner,
                remoteJobStore: store,
                remotePurchases: purchases,
                refreshSkipZones: { 0 }
            )
        }

        /// Continue in Background for the running cloud drain, then the
        /// system launches the task.
        func armAndLaunch() -> FakeAdFreePassContinuedTaskHandle {
            session.arm(episodeTitle: "Cloud Episode", requiresGPU: false, cancellationSource: pass.cancellationSource)
            let handle = FakeAdFreePassContinuedTaskHandle()
            scheduler.launch(handle)
            return handle
        }

        /// Waits for the drain to stop running and reports whether it parked.
        func waitForDrainToStop() async -> Bool {
            await waitUntil { pass.queueState != .running && pass.activeEpisodeID == nil }
        }

        func pipeline(for episodeID: String) -> EpisodePipelineState? {
            EpisodePipelineState.make(
                episodeID: episodeID,
                queueStatus: pass.queueStatus(for: episodeID),
                queueSnapshot: pass.queueSnapshot,
                downloadRecord: device.downloads.record(for: episodeID),
                transcription: .unavailable,
                analysis: nil
            )
        }

        func soundLab(for episode: EpisodeListItemSnapshot) -> EpisodeAdFreePassPresentation {
            pass.presentation(
                for: episode,
                downloads: device.downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: device.transcriptions,
                adAnalyses: device.adAnalyses,
                currentZoneCount: 0
            )
        }
    }

    // MARK: Expiration parks (fixture cloudParked)

    @Test("Expiration parks the cloud head with a persisted reason, never cancels, and Resume re-attaches the same job after relaunch")
    func expirationParksCloudHeadAndPersistsReason() async throws {
        let fixture = RemoteJobRecoveryFixture.cloudParked
        let device = try await makeDevice(episodeIDs: ["ep-cloud-expire"], api: fixture.makeAPI())
        let episode = device.episode("ep-cloud-expire")
        let seed = try #require(try fixture.seedPersistedState(
            store: device.seedStore, api: device.api, modelContext: device.context, episode: episode
        ))

        let first = device.launch()
        first.restoreQueue()
        #expect(await waitUntil { device.api.pollCalls.contains { $0.jobID == seed.jobID } })
        let handle = first.armAndLaunch()
        #expect(first.scheduler.submittedGPUFlags == [false])

        handle.expire()
        #expect(await first.waitForDrainToStop())

        // One expiration completion; the system task never decides the job.
        #expect(handle.completions == [false])
        #expect(first.pass.cancellationSource.lastCancellationReason == .sessionExpiration)
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.api.mintedJobIDs == [seed.jobID])
        let kept = try #require(device.reference(episode.episodeID))
        #expect(kept.jobID == seed.jobID)
        #expect(kept.createState == .attached)
        #expect(kept.userCancelRequestedAt == nil)

        // The item stays at the head with its reason, in memory and on disk.
        #expect(first.pass.queueState == .pausedInterrupted)
        #expect(first.pass.queueItems.map(\.episodeID) == [episode.episodeID])
        #expect(first.pass.queueItems.first?.remoteParkReason == .parked)
        #expect(first.pass.queueSnapshot.remoteParkedHeadReason == .parked)
        #expect(first.pass.queueStatus(for: episode.episodeID) == .remoteParked(.parked))
        #expect(try device.record(episode.episodeID)?.remoteParkReasonRawValue == RemoteTranscriptionJobExit.parked.rawValue)
        // Not a failure: the drain reports nothing finished, and its
        // terminal is the cloud park, never the on-device interrupt.
        #expect(first.pass.drainOutcomes.isEmpty)
        #expect(first.terminals.values == [.remoteParked(.parked)])

        // Every queue surface offers Resume on the same job.
        let queue = AdDetectionQueuePresentation(snapshot: first.pass.queueSnapshot, isBackgroundSessionArmed: first.session.isArmed)
        #expect(queue.rows.map(\.status) == [.remoteParked(.parked)])
        #expect(queue.affordance == .resumeInterrupted)
        let pipeline = try #require(first.pipeline(for: episode.episodeID))
        #expect(pipeline.action == .cancelPass)
        #expect(pipeline.footerAction == .resumeQueue)
        #expect(first.soundLab(for: episode) == .remoteParked(.parked))

        // The trail explains the park and holds no cancel.
        #expect(device.diagnostics.containsInOrder([.sessionExpired, .parked]))
        #expect(device.diagnostics.events(of: .sessionExpired).first?.clientRequestID == seed.reference.clientRequestID)
        #expect(device.diagnostics.events(of: .cancelAttempted).isEmpty)

        // Relaunch: the persisted reason restores, and the queue re-attaches
        // the seeded job by its original client request ID.
        let pollsBeforeRelaunch = device.api.pollCalls.count
        let second = device.launch()
        second.restoreQueue()
        let restored = try #require(second.pass.queueItems.first)
        #expect(restored.remoteParkReason == .parked)
        #expect(await waitUntil { device.api.pollCalls.count > pollsBeforeRelaunch })
        #expect(device.api.pollCalls.last?.jobID == seed.jobID)
        #expect(Set(device.api.createRequests.map(\.clientRequestID)) == [seed.reference.clientRequestID])
        #expect(device.api.mintedJobIDs == [seed.jobID])
        #expect(device.api.cancelCalls.isEmpty)
        // A running item is no longer parked.
        #expect(await waitUntil { (try? device.record(episode.episodeID))?.remoteParkReasonRawValue == "" })
        #expect(second.pass.queueStatus(for: episode.episodeID) == .running)

        second.pass.reset()
    }

    // MARK: Removal is the user cancel (fixture parkedCloudUserCancel)

    @Test("Removing a parked cloud item persists the intent first, sends exactly one cancel, then deletes the record; activation never re-attaches it")
    func removingParkedCloudItemSendsOneUserCancel() async throws {
        let fixture = RemoteJobRecoveryFixture.parkedCloudUserCancel
        let device = try await makeDevice(episodeIDs: ["ep-cloud-remove"], api: fixture.makeAPI())
        let episode = device.episode("ep-cloud-remove")
        let seed = try #require(try fixture.seedPersistedState(
            store: device.seedStore, api: device.api, modelContext: device.context, episode: episode
        ))
        let process = device.launch()
        process.restoreQueue()
        #expect(await waitUntil { device.api.pollCalls.contains { $0.jobID == seed.jobID } })
        process.armAndLaunch().expire()
        #expect(await process.waitForDrainToStop())
        #expect(process.pass.queueStatus(for: episode.episodeID) == .remoteParked(.parked))
        #expect(device.api.cancelCalls.isEmpty)

        let cancelGate = RemoteJobFaultInjectingAPI.Gate()
        device.api.inject(.delayed(cancelGate), at: .cancel)
        let removal = process.pass.removePendingItem(episodeID: episode.episodeID, modelContext: device.context)

        // Intent before anything else, and the item leaves the queue at once.
        #expect(device.reference(episode.episodeID)?.userCancelRequestedAt != nil)
        #expect(process.pass.queueItems.isEmpty)
        #expect(process.pass.queueStatus(for: episode.episodeID) == .notQueued)
        let cancellation = try #require(removal)
        // A repeated tap while the cancel is in flight does nothing.
        #expect(process.pass.removePendingItem(episodeID: episode.episodeID, modelContext: device.context) == nil)

        // While the one cancel is in flight the record stays, so a death here
        // leaves a record the next launch drops and an intent it resolves.
        #expect(await waitUntil { cancelGate.isHoldingRequest })
        #expect(try device.record(episode.episodeID) != nil)
        #expect(device.api.serverState(of: seed.jobID) == .transcribing)
        cancelGate.release()
        await cancellation.value

        #expect(device.api.cancelCalls.map(\.jobID) == [seed.jobID])
        #expect(device.api.serverState(of: seed.jobID) == .cancelled)
        #expect(device.reference(episode.episodeID) == nil)
        #expect(try device.record(episode.episodeID) == nil)
        #expect(device.diagnostics.containsInOrder([.userCancelRequested, .cancelAttempted, .referenceCleared]))
        #expect(process.pass.queueState == .idle)

        // Activation: neither the queue nor the re-attach trigger brings it back.
        let pollsAfterCancel = device.api.pollCalls.count
        let createsAfterCancel = device.api.createCalls.count
        process.pass.resumeRemoteParkedQueueIfNeeded()
        let reattacher = RemoteJobReattacher(
            plainTranscription: EpisodeRemoteTranscriptionCoordinator(
                api: device.api,
                downloads: device.downloads,
                transcriptions: device.transcriptions,
                store: process.store
            ),
            cloudRunner: process.runner,
            transcriptions: device.transcriptions,
            resolveEpisode: { _ in episode },
            cloudQueueEpisodeIDs: { Set(process.pass.queueItems.map(\.episodeID)) }
        )
        await reattacher.reattachIfNeeded(modelContext: device.context).value
        #expect(process.pass.activeEpisodeID == nil)
        #expect(device.api.pollCalls.count == pollsAfterCancel)
        #expect(device.api.createCalls.count == createsAfterCancel)
        #expect(device.api.cancelCalls.count == 1)
        #expect(device.api.mintedJobIDs == [seed.jobID])
    }

    // MARK: Post-attach failures park

    @Test(
        "A post-attach connection loss or local request failure keeps the cloud item at the head with Resume, never a dropped paid job",
        arguments: [
            (RemoteJobRecoveryFixture.transportAfterAttach, RemoteTranscriptionJobExit.connectionLost),
            (RemoteJobRecoveryFixture.localLegFailure, RemoteTranscriptionJobExit.localRequestFailed),
        ]
    )
    func postAttachFailureParksCloudHead(
        fixture: RemoteJobRecoveryFixture,
        reason: RemoteTranscriptionJobExit
    ) async throws {
        let episodeID = "ep-cloud-\(fixture.rawValue)"
        let device = try await makeDevice(episodeIDs: [episodeID], api: fixture.makeAPI())
        let episode = device.episode(episodeID)
        let process = device.launch()

        process.enqueueCloud(episode)
        #expect(await waitUntil { device.reference(episodeID)?.jobID != nil })
        #expect(await process.waitForDrainToStop())

        let reference = try #require(device.reference(episodeID))
        #expect(reference.createState == .attached)
        #expect(reference.lastExit == reason)
        #expect(device.api.cancelCalls.isEmpty)
        #expect(process.pass.queueState == .pausedInterrupted)
        #expect(process.pass.queueItems.map(\.episodeID) == [episodeID])
        #expect(process.pass.queueStatus(for: episodeID) == .remoteParked(reason))
        #expect(try device.record(episodeID)?.remoteParkReasonRawValue == reason.rawValue)
        #expect(process.pass.drainOutcomes.isEmpty)
        #expect(process.terminals.values == [.remoteParked(reason)])
        #expect(process.pipeline(for: episodeID)?.action == .cancelPass)
        #expect(process.pipeline(for: episodeID)?.footerAction == .resumeQueue)

        // Resume goes back to the same job, even while the fault persists.
        let jobID = try #require(reference.jobID)
        let pollsBeforeResume = device.api.pollCalls.count
        process.pass.resumePausedQueue()
        #expect(await waitUntil { device.api.pollCalls.count > pollsBeforeResume })
        #expect(await process.waitForDrainToStop())
        #expect(device.api.pollCalls.allSatisfy { $0.jobID == jobID })
        #expect(device.api.mintedJobIDs == [jobID])
        #expect(Set(device.api.createRequests.map(\.clientRequestID)) == [reference.clientRequestID])
        #expect(device.api.cancelCalls.isEmpty)
        #expect(process.pass.queueStatus(for: episodeID) == .remoteParked(reason))
        #expect(process.terminals.values == [.remoteParked(reason), .remoteParked(reason)])
    }

    @Test("A local failure before any create attempt stays the cloud-unavailable outcome: no server job exists to park")
    func preparedReferenceFailureStaysCloudUnavailable() async throws {
        let api = RemoteJobFaultInjectingAPI(pollScript: [
            OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing),
        ])
        api.inject(.localFailure(AppAttestKeychainError(status: -25300)), at: .bootstrap, times: .max)
        let device = try await makeDevice(episodeIDs: ["ep-cloud-prepared"], api: api)
        let process = device.launch()

        process.enqueueCloud(device.episode("ep-cloud-prepared"))
        #expect(await waitUntil { process.pass.queueState == .idle && !process.pass.drainOutcomes.isEmpty })

        #expect(device.api.createCalls.isEmpty)
        #expect(device.reference("ep-cloud-prepared")?.createState == .prepared)
        #expect(process.pass.queueItems.isEmpty)
        #expect(process.terminals.values == [.drained(completedCount: 0, failedCount: 1)])
        #expect(process.pass.drainOutcomes.first?.completionDeliveryOwner == .local)
        guard case .cloudUnavailable = process.pass.queueStatus(for: "ep-cloud-prepared") else {
            Issue.record("expected cloudUnavailable, got \(process.pass.queueStatus(for: "ep-cloud-prepared"))")
            return
        }
        #expect(try device.record("ep-cloud-prepared") == nil)
    }

    // MARK: Active user cancel

    @Test("Cancelling the running cloud item persists the intent before the local task stops, sends one cancel, and keeps the record until it lands")
    func activeCloudCancelPersistsIntentFirst() async throws {
        let device = try await makeDevice(
            episodeIDs: ["ep-cloud-active-cancel"],
            api: RemoteJobRecoveryFixture.cloudParked.makeAPI()
        )
        let episodeID = "ep-cloud-active-cancel"
        let process = device.launch()
        process.enqueueCloud(device.episode(episodeID))
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        let jobID = try #require(device.reference(episodeID)?.jobID)

        let cancelGate = RemoteJobFaultInjectingAPI.Gate()
        device.api.inject(.delayed(cancelGate), at: .cancel)
        process.pass.cancelActivePass()

        // Persisted synchronously, before the drain task sees its cancellation.
        #expect(device.reference(episodeID)?.userCancelRequestedAt != nil)
        #expect(await process.waitForDrainToStop())
        #expect(process.terminals.values == [.cloudUserCancelled])
        #expect(await waitUntil { cancelGate.isHoldingRequest })
        #expect(try device.record(episodeID) != nil)
        #expect(process.pass.queueStatus(for: episodeID) == .notQueued)

        cancelGate.release()
        #expect(await waitUntil { (try? device.record(episodeID)) == nil })
        #expect(device.api.cancelCalls.map(\.jobID) == [jobID])
        #expect(device.reference(episodeID) == nil)
        #expect(device.diagnostics.containsInOrder([.userCancelRequested, .cancelAttempted, .referenceCleared]))
    }

    @Test("Cancelling a replacement while the old cancellation waits does not restore its record")
    func replacementCancellationDoesNotResurrectRecord() async throws {
        let device = try await makeDevice(episodeIDs: ["review-cancel"], api: RemoteJobRecoveryFixture.cloudParked.makeAPI())
        var preparationCount = 0
        let process = device.launch(launchPreparationGate: { @MainActor in
            preparationCount += 1
        })
        let episode = device.episode("review-cancel")
        process.enqueueCloud(episode)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        let cancelGate = RemoteJobFaultInjectingAPI.Gate()
        device.api.inject(.delayed(cancelGate), at: .cancel)
        process.pass.cancelActivePass()
        #expect(await process.waitForDrainToStop())
        #expect(await waitUntil { cancelGate.isHoldingRequest })

        process.enqueueCloud(episode)
        // Preparation runs on the main actor up to its next suspension:
        // waiting for the still-gated server cancellation.
        #expect(await waitUntil { preparationCount == 2 })
        #expect(process.pass.queueItems.map(\.episodeID) == [episode.episodeID])
        let removal = try #require(process.pass.removePendingItem(episodeID: episode.episodeID, modelContext: device.context))
        cancelGate.release()
        await removal.value
        #expect(await process.waitForDrainToStop())
        #expect(process.pass.queueItems.isEmpty)
        #expect(try device.record(episode.episodeID) == nil)
        let restored = device.launch()
        restored.restoreQueue()
        #expect(restored.pass.queueItems.isEmpty)
        #expect(device.api.mintedJobIDs.count == 1)
        process.pass.reset()
    }

    @Test("Local work appended to a cloud card uses non-GPU compute")
    func appendingDeviceWorkUsesNonGPUCompute() async throws {
        let device = try await makeDevice(episodeIDs: ["review-cloud", "review-device"], api: RemoteJobRecoveryFixture.cloudParked.makeAPI())
        let rig = makeAppModel(device)
        rig.adFreeScheduler.supportsGPUResources = true
        rig.appModel.startAdFreePass(for: device.episode("review-cloud"), modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        rig.adFreeScheduler.launch(FakeAdFreePassContinuedTaskHandle())
        rig.appModel.startAdFreePass(for: device.episode("review-device"), modelContext: device.context, mode: .onDevice)
        #expect(await waitUntil { (try? device.record("review-device")) != nil })
        #expect(rig.appModel.adFreePass.holdsOnDeviceWork)
        #expect(rig.adFreeScheduler.submittedGPUFlags == [false])
        #expect(rig.appModel.adFreePass.initialWhisperComputeProfile == .cpuAndNeuralEngine)
        #expect(OpenCastEpisodeTranscriber.resolvedComputeProfile(
            requestedProfile: rig.appModel.adFreePass.initialWhisperComputeProfile,
            supportsBackgroundGPU: true
        ) == .cpuAndNeuralEngine)
        rig.appModel.adFreePassBackgroundSession.reset()
        #expect(rig.appModel.adFreePass.initialWhisperComputeProfile == .backgroundSafe)
        rig.appModel.adFreePass.reset()
    }

    // MARK: App model wiring

    @Test("A manual cloud start arms the ad-free card without GPU")
    func manualCloudStartArmsWithoutGPU() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-app-manual"], api: RemoteJobRecoveryFixture.cloudParked.makeAPI())
        let rig = makeAppModel(device)
        rig.adFreeScheduler.supportsGPUResources = true

        rig.appModel.startAdFreePass(for: device.episode("ep-app-manual"), modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })

        #expect(rig.adFreeScheduler.submittedGPUFlags == [false])
        #expect(rig.appModel.adFreePassBackgroundSession.isArmed)
        #expect(device.diagnostics.events(of: .sessionArmed).map(\.episodeID) == ["ep-app-manual"])
        rig.appModel.adFreePass.reset()
    }

    @Test("An auto-origin cloud pass stays foreground-only until Continue in Background")
    func autoCloudStaysForegroundOnlyUntilContinueInBackground() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-app-auto"], api: RemoteJobRecoveryFixture.cloudParked.makeAPI())
        let episode = device.episode("ep-app-auto")
        let rig = makeAppModel(device)
        rig.adFreeScheduler.supportsGPUResources = true
        device.context.insert(SubscriptionRecord(feedURL: episode.podcastID, title: "Example Show", isAdAutoDetectEnabled: true))
        try device.context.save()
        await rig.appModel.library.load(modelContext: device.context)
        #expect(rig.appModel.adDetectionSettings.setMode(.cloud, modelContext: device.context))

        try rig.appModel.playEpisode(episode, modelContext: device.context)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        #expect(rig.appModel.adFreePass.activeItem?.origin == .auto)
        #expect(rig.appModel.adFreePass.activeItem?.mode == .cloud)
        #expect(rig.adFreeScheduler.submitCallCount == 0)

        let queue = AdDetectionQueuePresentation(
            snapshot: rig.appModel.adFreePass.queueSnapshot,
            isBackgroundSessionArmed: rig.appModel.adFreePassBackgroundSession.isArmed
        )
        #expect(queue.affordance == .continueInBackground)
        rig.appModel.armBackgroundContinuationForActiveQueue()
        #expect(rig.adFreeScheduler.submittedGPUFlags == [false])
        rig.appModel.adFreePass.reset()
    }

    @Test("While the transcript-generation card is armed, the ad-free card stays foreground-only for cloud and on-device starts")
    func oneCardGuardCoversTranscriptGeneration() async throws {
        let device = try await makeDevice(
            episodeIDs: ["ep-app-cloud-guard", "ep-app-device-guard"],
            api: RemoteJobRecoveryFixture.cloudParked.makeAPI()
        )
        let rig = makeAppModel(device)
        rig.appModel.transcriptGenerationBackgroundSession.arm(episodeTitle: "Generating")
        #expect(rig.appModel.transcriptGenerationBackgroundSession.isArmed)

        rig.appModel.startAdFreePass(for: device.episode("ep-app-cloud-guard"), modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        rig.appModel.startAdFreePass(for: device.episode("ep-app-device-guard"), modelContext: device.context, mode: .onDevice)
        #expect(await waitUntil { (try? device.record("ep-app-device-guard")) != nil })
        rig.appModel.armBackgroundContinuationForActiveQueue()

        #expect(rig.adFreeScheduler.submitCallCount == 0)
        #expect(!rig.appModel.adFreePassBackgroundSession.isArmed)
        #expect(device.diagnostics.events(of: .sessionForegroundOnly).map(\.episodeID).contains("ep-app-cloud-guard"))
        rig.appModel.adFreePass.reset()
    }

    @Test("A live card holding a cloud item does not count as protection for local work")
    func cloudCardDoesNotProtectLocalWork() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-app-protect"], api: RemoteJobRecoveryFixture.cloudParked.makeAPI())
        let rig = makeAppModel(device)

        rig.appModel.startAdFreePass(for: device.episode("ep-app-protect"), modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        rig.adFreeScheduler.launch(FakeAdFreePassContinuedTaskHandle())

        #expect(rig.appModel.adFreePassBackgroundSession.isProtectingBackgroundExecution)
        #expect(!rig.appModel.isProtectingLocalBackgroundWork)
        rig.appModel.adFreePass.reset()
    }

    @Test("Scene activation re-attaches a parked cloud head foreground-only, through the same job")
    func activationResumesParkedCloudHead() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-app-activate"], api: RemoteJobRecoveryFixture.cloudParked.makeAPI())
        let rig = makeAppModel(device)
        let handle = FakeAdFreePassContinuedTaskHandle()

        rig.appModel.startAdFreePass(for: device.episode("ep-app-activate"), modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count > 0 })
        rig.adFreeScheduler.launch(handle)
        handle.expire()
        #expect(await waitUntil {
            rig.appModel.adFreePass.queueStatus(for: "ep-app-activate") == .remoteParked(.parked)
        })
        let pollsAtPark = device.api.pollCalls.count

        rig.appModel.resumeEnvironmentalAdFreePassIfNeeded(modelContext: device.context)

        #expect(await waitUntil { rig.appModel.adFreePass.activeEpisodeID == "ep-app-activate" })
        #expect(await waitUntil { device.api.pollCalls.count > pollsAtPark })
        #expect(device.api.mintedJobIDs == ["job-fake-1"])
        #expect(device.api.cancelCalls.isEmpty)
        // An automatic resume never submits a continued-processing task.
        #expect(rig.adFreeScheduler.submitCallCount == 1)
        rig.appModel.adFreePass.reset()
    }

    // MARK: Helpers

    @MainActor
    private struct AppRig {
        let appModel: OpenCastAppModel
        let adFreeScheduler: FakeAdFreePassContinuedTaskScheduler
    }

    private func makeAppModel(_ device: Device) -> AppRig {
        let adFreeScheduler = FakeAdFreePassContinuedTaskScheduler()
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
            transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession(
                scheduler: FakeAdFreePassContinuedTaskScheduler()
            ),
            allowsAutomaticFeedRefresh: false,
            adFreePassNotificationCenter: FakeAdFreePassNotificationCenter()
        )
        appModel.configureBackgroundSessionExpirations(modelContext: device.context)
        return AppRig(appModel: appModel, adFreeScheduler: adFreeScheduler)
    }

    /// Builds a device whose episodes each have a completed download with a
    /// known source identity, so a cloud run reaches the poll leg.
    private func makeDevice(
        episodeIDs: [String],
        api: RemoteJobFaultInjectingAPI
    ) async throws -> Device {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        try downloadFileStore.prepareDownloadsDirectory()

        var episodes: [EpisodeListItemSnapshot] = []
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
            let record = EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: episode.podcastID,
                sourceAudioURL: sourceURL.absoluteString,
                localRelativePath: relativePath,
                state: .completed,
                bytesReceived: Int64(data.count),
                bytesExpected: Int64(data.count)
            )
            record.sourceFileSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            record.duration = 120
            context.insert(record)
            episodes.append(episode)
        }
        try context.save()
        await downloads.load(modelContext: context)

        let suiteName = "cloud-continuation-tests-\(UUID().uuidString)"
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
            .appending(path: "OpenCastCloudContinuationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
