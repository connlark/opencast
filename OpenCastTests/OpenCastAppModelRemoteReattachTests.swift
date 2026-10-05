import CryptoKit
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// Launch and scene-activation recovery: kept references re-attach
/// by their original client request ID without a second tap or a second job,
/// a persisted user cancel is retried once per trigger instead of polling,
/// housekeeping drops only expired references, and a persisted cloud head
/// resumes through the queue's own path.
///
/// A "relaunch" builds a new store, coordinator, runner and reattacher over
/// the same defaults, model context and fake server, so nothing held only in
/// the earlier process's memory survives.
@MainActor
@Suite("Remote job re-attach", .serialized)
struct OpenCastAppModelRemoteReattachTests {
    @MainActor
    private struct Device {
        let api: RemoteJobFaultInjectingAPI
        let defaults: UserDefaults
        let diagnostics: RecordingRemoteJobDiagnosticSink
        let transcriptions: EpisodeTranscriptionStore
        let downloads: DownloadStore
        let context: ModelContext
        let episodes: [EpisodeListItemSnapshot]
        let identities: [String: OpenCastRemoteTranscriptionSourceIdentity]

        /// Persisted state an earlier process wrote, through the real store
        /// but with a throwaway sink so the trail under test starts clean.
        var seedStore: RemoteTranscriptionJobStore {
            RemoteTranscriptionJobStore(defaults: defaults, diagnostics: RecordingRemoteJobDiagnosticSink())
        }

        func episode(_ episodeID: String) -> EpisodeListItemSnapshot {
            episodes.first { $0.episodeID == episodeID }!
        }

        func references() -> [RemoteTranscriptionJobReference] {
            seedStore.references()
        }

        func reference(
            _ episodeID: String,
            _ purpose: RemoteTranscriptionJobPurpose = .transcription
        ) -> RemoteTranscriptionJobReference? {
            seedStore.existingReference(for: episodeID, purpose: purpose)
        }

        /// Writes references as an earlier process (or an earlier day) left
        /// them, including their creation time.
        func writeReferences(_ references: [RemoteTranscriptionJobReference]) throws {
            defaults.set(try JSONEncoder().encode(references), forKey: "remoteTranscription.jobReferences")
        }

        func launch(
            unresolvedEpisodeIDs: Set<String> = [],
            cloudQueueEpisodeIDs: @escaping () -> Set<String> = { [] }
        ) -> AppSession {
            let store = RemoteTranscriptionJobStore(defaults: defaults, diagnostics: diagnostics)
            let coordinator = EpisodeRemoteTranscriptionCoordinator(
                api: api,
                downloads: downloads,
                transcriptions: transcriptions,
                store: store,
                transportRetryDelays: [],
                localRetryDelays: []
            )
            let cloudRunner = RemoteTranscriptionJobRunner(
                api: api,
                downloads: downloads,
                transcriptions: transcriptions,
                store: store,
                transportRetryDelays: [],
                localRetryDelays: []
            )
            let episodes = episodes
            let reattacher = RemoteJobReattacher(
                plainTranscription: coordinator,
                cloudRunner: cloudRunner,
                transcriptions: transcriptions,
                resolveEpisode: { episodeID in
                    unresolvedEpisodeIDs.contains(episodeID) ? nil : episodes.first { $0.episodeID == episodeID }
                },
                cloudQueueEpisodeIDs: cloudQueueEpisodeIDs
            )
            return AppSession(store: store, coordinator: coordinator, cloudRunner: cloudRunner, reattacher: reattacher)
        }
    }

    @MainActor
    private struct AppSession {
        let store: RemoteTranscriptionJobStore
        let coordinator: EpisodeRemoteTranscriptionCoordinator
        let cloudRunner: RemoteTranscriptionJobRunner
        let reattacher: RemoteJobReattacher

        func trigger(_ device: Device) async {
            await reattacher.reattachIfNeeded(modelContext: device.context).value
        }

        /// Stops a live re-attached run without any server decision.
        func park() async {
            coordinator.park(exit: .parked)
            _ = await waitUntil { store.phase == .parkedOnServer(.parked) }
        }
    }

    // MARK: Re-attach (Required Verification 1–2)

    @Test("Launch re-attaches a parked reference with a job ID by its original client request ID")
    func launchReattachesParkedReference() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-launch-parked"])
        let seeded = seedAttached(device, "ep-launch-parked", exit: .parked)

        let process = device.launch()
        await process.trigger(device)

        #expect(await waitUntil { device.api.pollCalls.contains { $0.jobID == "job-seeded-1" } })
        #expect(process.store.phase(for: "ep-launch-parked")?.isTerminal == false)
        #expect(device.api.createRequests.map(\.clientRequestID) == [seeded.clientRequestID])
        #expect(device.api.mintedJobIDs == ["job-seeded-1"])
        #expect(device.api.cancelCalls.isEmpty)
        let reattached = try #require(device.reference("ep-launch-parked"))
        #expect(reattached.clientRequestID == seeded.clientRequestID)
        #expect(reattached.jobID == "job-seeded-1")
        // The park reason holds until the re-attach takes the job back.
        #expect(reattached.lastExit == nil)
        #expect(device.diagnostics.events(of: .reattachStarted).map(\.clientRequestID) == [seeded.clientRequestID])
        #expect(device.diagnostics.events(of: .reattachStarted).first?.component == .reattach)
        await process.park()
    }

    @Test("Launch re-attaches a younger createAttempted reference without a job ID through the same client request ID")
    func launchReattachesUncertainCreateBySameClientID() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-launch-uncertain"])
        let seedStore = device.seedStore
        let minted = seedStore.reference(for: "ep-launch-uncertain")
        seedStore.markCreateAttempted(episodeID: "ep-launch-uncertain")
        // The earlier process's create reached the server; its response was lost.
        device.api.seedServerJob(clientRequestID: minted.clientRequestID, jobID: "job-seeded-1", state: .transcribing)

        let process = device.launch()
        await process.trigger(device)

        #expect(await waitUntil { device.reference("ep-launch-uncertain")?.createState == .attached })
        let attached = try #require(device.reference("ep-launch-uncertain"))
        #expect(attached.clientRequestID == minted.clientRequestID)
        #expect(attached.jobID == "job-seeded-1")
        #expect(device.api.createRequests.map(\.clientRequestID) == [minted.clientRequestID])
        #expect(device.api.mintedJobIDs == ["job-seeded-1"])
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.diagnostics.containsInOrder([.reattachStarted, .createAttached]))
        await process.park()
    }

    // MARK: Housekeeping (Required Verification 3)

    @Test("Launch drops only references older than seven days and retains younger uncertain cloud and transcription references")
    func housekeepingDropsOnlyExpiredReferences() async throws {
        let device = try await makeDevice(episodeIDs: [
            "ep-expired", "ep-expired-cloud", "ep-queued-old-cloud",
            "ep-young-cloud", "ep-young-unresolved", "ep-young-prepared",
        ])
        let eightDaysAgo = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        let sixDaysAgo = Date.now.addingTimeInterval(-6 * 24 * 60 * 60)
        let expired = RemoteTranscriptionJobReference(
            episodeID: "ep-expired", clientRequestID: "crid-expired", jobID: "job-old",
            createdAt: eightDaysAgo, purpose: .transcription, lastExit: .parked
        )
        let expiredCloud = RemoteTranscriptionJobReference(
            episodeID: "ep-expired-cloud", clientRequestID: "crid-expired-cloud", jobID: nil,
            createdAt: eightDaysAgo, purpose: .adDetection, createState: .createAttempted
        )
        // The queue still holds this head; its reference is the queue's to resolve.
        let queuedOldCloud = RemoteTranscriptionJobReference(
            episodeID: "ep-queued-old-cloud", clientRequestID: "crid-queued-old-cloud", jobID: "job-queued",
            createdAt: eightDaysAgo, purpose: .adDetection, lastExit: .parked
        )
        // No queue record and no active item: still not proof the job is gone.
        let youngCloud = RemoteTranscriptionJobReference(
            episodeID: "ep-young-cloud", clientRequestID: "crid-young-cloud", jobID: nil,
            createdAt: sixDaysAgo, purpose: .adDetection, createState: .createAttempted, lastExit: .connectionLost
        )
        let youngUnresolved = RemoteTranscriptionJobReference(
            episodeID: "ep-young-unresolved", clientRequestID: "crid-young-unresolved", jobID: nil,
            createdAt: sixDaysAgo, purpose: .transcription, createState: .createAttempted
        )
        let youngPrepared = RemoteTranscriptionJobReference(
            episodeID: "ep-young-prepared", clientRequestID: "crid-young-prepared", jobID: nil,
            createdAt: sixDaysAgo, purpose: .transcription
        )
        try device.writeReferences([expired, expiredCloud, queuedOldCloud, youngCloud, youngUnresolved, youngPrepared])

        let process = device.launch(
            unresolvedEpisodeIDs: ["ep-young-unresolved"],
            cloudQueueEpisodeIDs: { ["ep-queued-old-cloud"] }
        )
        await process.trigger(device)

        let retained = device.references()
        #expect(Set(retained.map(\.clientRequestID)) == [
            "crid-queued-old-cloud", "crid-young-cloud", "crid-young-unresolved", "crid-young-prepared",
        ])
        #expect(retained.first { $0.clientRequestID == "crid-young-cloud" } == youngCloud)
        #expect(retained.first { $0.clientRequestID == "crid-young-unresolved" } == youngUnresolved)
        #expect(retained.first { $0.clientRequestID == "crid-young-prepared" } == youngPrepared)
        let expiredEvents = device.diagnostics.events(of: .housekeepingExpired)
        #expect(Set(expiredEvents.compactMap(\.clientRequestID)) == ["crid-expired", "crid-expired-cloud"])
        #expect(expiredEvents.allSatisfy { $0.disposition == .expired })
        // Nothing was minted, created or cancelled during cleanup.
        #expect(device.api.traffic.isEmpty)
        #expect(device.api.mintedJobIDs.isEmpty)
        let skipped = device.diagnostics.events(of: .reattachSkipped)
        #expect(skipped.first { $0.clientRequestID == "crid-young-unresolved" }?.disposition == .skippedUnresolvedEpisode)
        #expect(skipped.first { $0.clientRequestID == "crid-young-prepared" }?.disposition == .skippedNotCreated)
        #expect(device.diagnostics.events(of: .reattachStarted).isEmpty)
    }

    // MARK: Claim (Required Verification 4)

    @Test("Launch and activation racing each other start one task, and a later trigger waits while the run owns the episode")
    func launchAndActivationRaceStartsOneTask() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-race"])
        seedAttached(device, "ep-race", exit: .parked)
        let process = device.launch()

        let launch = process.reattacher.reattachIfNeeded(modelContext: device.context)
        let activation = process.reattacher.reattachIfNeeded(modelContext: device.context)
        #expect(launch == activation)
        await launch.value

        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        #expect(device.api.createCalls.count == 1)
        #expect(device.diagnostics.events(of: .reattachStarted).count == 1)

        await process.trigger(device)
        #expect(device.api.createCalls.count == 1)
        #expect(device.diagnostics.events(of: .reattachStarted).count == 1)
        #expect(device.diagnostics.events(of: .reattachSkipped).last?.disposition == .skippedActiveRequest)
        await process.park()
    }

    @Test("Scene activation waits for launch restore, then recovery resolves an episode from its retained download")
    func appModelGatesActivationOnLaunchRestore() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-app-model"])
        let seeded = seedAttached(device, "ep-app-model", exit: .parked)
        let appModel = makeAppModel(device)

        #expect(appModel.library.episode(with: "ep-app-model") == nil)
        #expect(appModel.reattachRemoteJobsIfNeeded(modelContext: device.context, trigger: .sceneActivated) == nil)
        #expect(device.api.traffic.isEmpty)
        appModel.restorePlaybackSurfaceIfNeeded(modelContext: device.context)
        let launch = try #require(appModel.reattachRemoteJobsIfNeeded(modelContext: device.context, trigger: .launch))
        await launch.value

        #expect(await waitUntil { device.api.pollCalls.contains { $0.jobID == "job-seeded-1" } })
        #expect(device.diagnostics.events(of: .reattachSkipped).isEmpty)
        #expect(device.api.createRequests.map(\.clientRequestID) == [seeded.clientRequestID])
        #expect(device.api.mintedJobIDs == ["job-seeded-1"])
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.reference("ep-app-model")?.jobID == "job-seeded-1")
        appModel.remoteTranscription.park(exit: .parked)
        #expect(await waitUntil { appModel.remoteTranscription.store.phase == .parkedOnServer(.parked) })
    }

    @Test("A retained download resolves a lost-create cancellation without a subscribed library episode", arguments: [
        RemoteTranscriptionJobPurpose.transcription, .adDetection,
    ])
    func appModelReplaysCancellationFromDownload(purpose: RemoteTranscriptionJobPurpose) async throws {
        let episodeID = "ep-download-cancel"
        let device = try await makeDevice(episodeIDs: [episodeID])
        let store = device.seedStore
        let reference = store.reference(for: episodeID, purpose: purpose)
        store.markCreateAttempted(episodeID: episodeID, purpose: purpose)
        store.recordUserCancelIntent(episodeID: episodeID, purpose: purpose)
        device.api.seedServerJob(clientRequestID: reference.clientRequestID, jobID: "job-seeded-1", state: .transcribing)
        let appModel = makeAppModel(device)

        #expect(appModel.library.episode(with: episodeID) == nil)
        appModel.restorePlaybackSurfaceIfNeeded(modelContext: device.context)
        let launch = try #require(appModel.reattachRemoteJobsIfNeeded(modelContext: device.context, trigger: .launch))
        await launch.value

        #expect(device.api.createRequests.map(\.clientRequestID) == [reference.clientRequestID])
        #expect(device.api.createRequests.first?.enclosureURL == device.episode(episodeID).audioURL)
        #expect((device.api.createRequests.first?.adAnalysisRequested == true) == (purpose == .adDetection))
        #expect(device.api.cancelCalls.map(\.jobID) == ["job-seeded-1"])
        #expect(device.api.serverState(of: "job-seeded-1") == .cancelled)
        #expect(device.api.mintedJobIDs == ["job-seeded-1"])
        #expect(device.api.pollCalls.isEmpty)
        #expect(device.reference(episodeID, purpose) == nil)
    }

    // MARK: Persisted user cancel (Required Verification 5)

    @Test("After a relaunch, a lost cancel response resolves the persisted intent once, without a replacement job or polling")
    func lostCancelResponseResolvesOnLaunch() async throws {
        let device = try await makeDevice(
            episodeIDs: ["ep-cancel-lost"],
            api: RemoteJobRecoveryFixture.cancelResponseLost.makeAPI()
        )
        let api = device.api
        let first = device.launch()
        first.coordinator.start(episode: device.episode("ep-cancel-lost"), modelContext: device.context)
        #expect(await waitUntil { api.pollCalls.count >= 1 })
        first.coordinator.cancel()
        await first.coordinator.userCancelTask?.value
        #expect(api.cancelCalls.count == 1)
        #expect(device.reference("ep-cancel-lost")?.userCancelRequestedAt != nil)

        let relaunched = device.launch()
        let pollsBefore = api.pollCalls.count
        let createsBefore = api.createCalls.count
        let runsBefore = device.diagnostics.events(of: .runStarted).count
        await relaunched.trigger(device)

        #expect(api.cancelCalls.map(\.jobID) == ["job-fake-1", "job-fake-1"])
        #expect(device.reference("ep-cancel-lost") == nil)
        #expect(api.pollCalls.count == pollsBefore)
        #expect(api.createCalls.count == createsBefore)
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(device.diagnostics.events(of: .runStarted).count == runsBefore)
        #expect(relaunched.store.phase(for: "ep-cancel-lost") == nil)

        // Nothing is left for the next trigger.
        await relaunched.trigger(device)
        #expect(api.cancelCalls.count == 2)
    }

    @Test("A cancel intent on a lost create replays the same client request ID after a relaunch, retrying once per trigger")
    func cancelIntentReplaysLostCreateAfterRelaunch() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-cancel-uncertain-create"])
        let seedStore = device.seedStore
        let minted = seedStore.reference(for: "ep-cancel-uncertain-create")
        seedStore.markCreateAttempted(episodeID: "ep-cancel-uncertain-create")
        seedStore.recordUserCancelIntent(episodeID: "ep-cancel-uncertain-create")
        device.api.seedServerJob(clientRequestID: minted.clientRequestID, jobID: "job-seeded-1", state: .transcribing)
        device.api.inject(.neverLeaves(URLError(.notConnectedToInternet)), at: .cancel)

        let process = device.launch()
        await process.trigger(device)

        // The episode rebuilt the lost create, so the job id is now known;
        // the cancel itself never left, so the intent stays.
        #expect(device.api.createRequests.map(\.clientRequestID) == [minted.clientRequestID])
        #expect(device.api.cancelCalls.count == 1)
        let uncertain = try #require(device.reference("ep-cancel-uncertain-create"))
        #expect(uncertain.jobID == "job-seeded-1")
        #expect(uncertain.userCancelRequestedAt != nil)
        #expect(device.api.pollCalls.isEmpty)
        #expect(device.diagnostics.events(of: .reattachSkipped).last?.disposition == .skippedCancelIntent)

        await process.trigger(device)

        #expect(device.api.cancelCalls.map(\.jobID) == ["job-seeded-1", "job-seeded-1"])
        #expect(device.api.serverState(of: "job-seeded-1") == .cancelled)
        #expect(device.reference("ep-cancel-uncertain-create") == nil)
        #expect(device.api.createRequests.count == 1)
        #expect(device.api.mintedJobIDs == ["job-seeded-1"])
        #expect(device.api.pollCalls.isEmpty)
        #expect(device.diagnostics.events(of: .reattachStarted).isEmpty)
    }

    // MARK: Suppression (Required Verification 6)

    @Test("Only the newest eligible plain reference re-attaches; a foreign transcript or a cloud-owned episode suppresses it")
    func suppressionAndNewestSelection() async throws {
        let device = try await makeDevice(episodeIDs: ["ep-older", "ep-newer", "ep-foreign-transcript", "ep-cloud-owned"])
        let now = Date.now
        let older = attachedReference("ep-older", createdAt: now.addingTimeInterval(-7_200))
        let newer = attachedReference("ep-newer", createdAt: now.addingTimeInterval(-3_600))
        let foreign = attachedReference("ep-foreign-transcript", createdAt: now)
        let cloudOwned = attachedReference("ep-cloud-owned", createdAt: now.addingTimeInterval(-60))
        try device.writeReferences([older, newer, foreign, cloudOwned])
        for reference in [older, newer, foreign, cloudOwned] {
            device.api.seedServerJob(clientRequestID: reference.clientRequestID, jobID: reference.jobID!, state: .transcribing)
        }
        // A transcript from another job is already on the device.
        _ = try await importDocument(device, episodeID: "ep-foreign-transcript", jobID: "job-other")

        let process = device.launch(cloudQueueEpisodeIDs: { ["ep-cloud-owned"] })
        await process.trigger(device)

        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        #expect(device.api.createRequests.map(\.clientRequestID) == [newer.clientRequestID])
        #expect(device.diagnostics.events(of: .reattachStarted).map(\.clientRequestID) == [newer.clientRequestID])
        let skipped = Dictionary(
            device.diagnostics.events(of: .reattachSkipped).compactMap { event in
                event.disposition.map { (event.clientRequestID ?? "", $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(skipped[foreign.clientRequestID] == .skippedCompletedTranscript)
        #expect(skipped[cloudOwned.clientRequestID] == .skippedActiveRequest)
        #expect(skipped[older.clientRequestID] == .skippedActiveRequest)
        #expect(device.references().count == 4)
        #expect(device.api.cancelCalls.isEmpty)
        await process.park()
    }

    // MARK: Acknowledgement through the launch trigger (CONTRACTS §7)

    @Test("Launch after death following import re-imports idempotently, acks and clears")
    func deathAfterImportReconcilesOnLaunch() async throws {
        let fixture = RemoteJobRecoveryFixture.deathAfterImport
        let device = try await makeDevice(episodeIDs: ["ep-launch-death-import"], fixture: fixture)
        let seed = try #require(try fixture.seedPersistedState(
            store: device.seedStore, api: device.api, modelContext: device.context,
            episode: device.episode("ep-launch-death-import")
        ))
        let imported = try await importDocument(device, episodeID: "ep-launch-death-import", jobID: seed.jobID)
        let priorPath = device.transcriptions.record(for: "ep-launch-death-import")?.transcriptRelativePath

        let process = device.launch()
        await process.trigger(device)

        #expect(await waitUntil { process.store.phase == .completed })
        #expect(device.api.ackCalls.map(\.jobID) == [seed.jobID])
        #expect(device.api.serverState(of: seed.jobID) == .acknowledged)
        #expect(device.api.createRequests.map(\.clientRequestID) == [seed.reference.clientRequestID])
        #expect(device.api.mintedJobIDs == [seed.jobID])
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.reference("ep-launch-death-import") == nil)
        #expect(device.transcriptions.record(for: "ep-launch-death-import")?.transcriptRelativePath == priorPath)
        #expect(device.transcriptions.document(for: "ep-launch-death-import")?.normalizedTranscriptSHA256
            == imported.normalizedTranscriptSHA256)
    }

    @Test("Launch after death following ack reconciles acknowledged as success and clears")
    func deathAfterAckReconcilesOnLaunch() async throws {
        let fixture = RemoteJobRecoveryFixture.deathAfterAck
        let device = try await makeDevice(episodeIDs: ["ep-launch-death-ack"], fixture: fixture)
        let seed = try #require(try fixture.seedPersistedState(
            store: device.seedStore, api: device.api, modelContext: device.context,
            episode: device.episode("ep-launch-death-ack")
        ))
        _ = try await importDocument(device, episodeID: "ep-launch-death-ack", jobID: seed.jobID)

        let process = device.launch()
        await process.trigger(device)

        #expect(await waitUntil { process.store.phase == .completed })
        #expect(device.api.resultCalls.isEmpty)
        #expect(device.api.ackCalls.isEmpty)
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.api.mintedJobIDs == [seed.jobID])
        #expect(device.reference("ep-launch-death-ack") == nil)
        #expect(device.diagnostics.events(of: .acknowledgedWithoutLocalImport).isEmpty)
        #expect(device.diagnostics.containsInOrder([.reattachStarted, .acknowledged, .referenceCleared]))
    }

    // MARK: Cloud queue (Required Verification 7)

    @Test("A persisted parked cloud head keeps its reason through launch and resumes through the queue without a new reference")
    func parkedCloudHeadResumesThroughQueue() async throws {
        let fixture = RemoteJobRecoveryFixture.cloudParked
        let device = try await makeDevice(episodeIDs: ["ep-cloud-parked"], api: fixture.makeAPI())
        let episode = device.episode("ep-cloud-parked")
        let seed = try #require(try fixture.seedPersistedState(
            store: device.seedStore, api: device.api, modelContext: device.context, episode: episode
        ))
        let pass = EpisodeAdFreePassCoordinator()
        let process = device.launch(cloudQueueEpisodeIDs: { Set(pass.queueItems.map(\.episodeID) + [pass.activeEpisodeID].compactMap { $0 }) })

        // Launch order: the queue restores first, then the re-attach trigger.
        restoreQueue(pass, device: device, process: process)
        await process.trigger(device)

        #expect(await waitUntil { device.api.pollCalls.contains { $0.jobID == seed.jobID } })
        #expect(device.api.createRequests.map(\.clientRequestID) == [seed.reference.clientRequestID])
        #expect(device.api.createRequests.first?.adAnalysisRequested == true)
        #expect(device.api.mintedJobIDs == [seed.jobID])
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.references().filter { $0.resolvedPurpose == .adDetection }.map(\.clientRequestID)
            == [seed.reference.clientRequestID])
        // The plain path never takes a cloud reference.
        #expect(device.diagnostics.events(of: .reattachStarted).isEmpty)
        // The drain's re-attach is the Resume that clears the park reason.
        #expect(device.reference("ep-cloud-parked", .adDetection)?.lastExit == nil)

        // A reset parks the reference again; it never cancels the job.
        pass.reset()
        #expect(await waitUntil { device.reference("ep-cloud-parked", .adDetection)?.lastExit == .parked })
        #expect(device.api.cancelCalls.isEmpty)
    }

    @Test("A persisted cloud head whose reference holds a cancel intent is not restored; the trigger sends its one cancel")
    func cancelledCloudHeadIsNotRestored() async throws {
        let fixture = RemoteJobRecoveryFixture.parkedCloudUserCancel
        let device = try await makeDevice(episodeIDs: ["ep-cloud-cancelled"], api: fixture.makeAPI())
        let episode = device.episode("ep-cloud-cancelled")
        let seed = try #require(try fixture.seedPersistedState(
            store: device.seedStore, api: device.api, modelContext: device.context, episode: episode
        ))
        device.seedStore.recordUserCancelIntent(episodeID: episode.episodeID, purpose: .adDetection)
        let pass = EpisodeAdFreePassCoordinator()
        let process = device.launch(cloudQueueEpisodeIDs: { Set(pass.queueItems.map(\.episodeID) + [pass.activeEpisodeID].compactMap { $0 }) })

        restoreQueue(pass, device: device, process: process)
        #expect(pass.queueItems.isEmpty)
        #expect(pass.activeEpisodeID == nil)
        #expect(try device.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)

        await process.trigger(device)

        #expect(device.api.cancelCalls.map(\.jobID) == [seed.jobID])
        #expect(device.api.serverState(of: seed.jobID) == .cancelled)
        #expect(device.reference("ep-cloud-cancelled", .adDetection) == nil)
        #expect(device.api.createCalls.isEmpty)
        #expect(device.api.pollCalls.isEmpty)
    }

    // MARK: Helpers

    private func makeAppModel(_ device: Device) -> OpenCastAppModel {
        OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: device.downloads,
            transcriptions: device.transcriptions,
            remoteTranscriptionAPI: device.api,
            remoteTranscriptionJobStore: RemoteTranscriptionJobStore(
                defaults: device.defaults,
                diagnostics: device.diagnostics
            ),
            allowsAutomaticFeedRefresh: false
        )
    }

    @discardableResult
    private func seedAttached(
        _ device: Device,
        _ episodeID: String,
        exit: RemoteTranscriptionJobExit?
    ) -> RemoteTranscriptionJobReference {
        let seedStore = device.seedStore
        let minted = seedStore.reference(for: episodeID)
        seedStore.markCreateAttempted(episodeID: episodeID)
        seedStore.attachJob(id: "job-seeded-1", episodeID: episodeID)
        seedStore.recordExit(exit, episodeID: episodeID)
        device.api.seedServerJob(clientRequestID: minted.clientRequestID, jobID: "job-seeded-1", state: .transcribing)
        return minted
    }

    private func attachedReference(_ episodeID: String, createdAt: Date) -> RemoteTranscriptionJobReference {
        RemoteTranscriptionJobReference(
            episodeID: episodeID,
            clientRequestID: "crid-\(episodeID)",
            jobID: "job-\(episodeID)",
            createdAt: createdAt,
            purpose: .transcription,
            lastExit: .parked
        )
    }

    private func restoreQueue(_ pass: EpisodeAdFreePassCoordinator, device: Device, process: AppSession) {
        let episodes = device.episodes
        pass.restorePersistedQueue(
            resolveEpisode: { episodeID in episodes.first { $0.episodeID == episodeID } },
            downloads: device.downloads,
            transcriptionModels: TranscriptionModelStore(),
            appleSpeechAssets: AppleSpeechAssetStore(),
            transcriptions: device.transcriptions,
            adAnalyses: EpisodeAdAnalysisStore(
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: FileManager.default.temporaryDirectory
                    .appending(path: "OpenCastReattachAdAnalyses-\(UUID().uuidString)", directoryHint: .isDirectory))
            ),
            modelContext: device.context,
            podcastLanguageCode: { _ in nil },
            remoteRunner: process.cloudRunner,
            remoteJobStore: process.store,
            remotePurchases: RemoteTranscriptionPurchaseStore(
                api: device.api,
                storeKit: LiveRemoteTranscriptionStoreKitClient()
            ),
            refreshSkipZones: { _ in 0 }
        )
    }

    private func importDocument(
        _ device: Device,
        episodeID: String,
        jobID: String
    ) async throws -> EpisodeTranscriptDocument {
        let episode = device.episode(episodeID)
        let identity = try #require(device.identities[episodeID])
        let document = try EpisodeRemoteTranscriptMapper.document(
            from: Self.result(identity: identity, durationSeconds: 120),
            context: EpisodeRemoteTranscriptMapper.Context(
                episodeID: episodeID,
                podcastID: episode.podcastID,
                sourceAudioURL: episode.audioURL!,
                localIdentity: identity,
                jobProvenanceToken: jobID
            )
        )
        try await device.transcriptions.importRemoteTranscript(document, modelContext: device.context)
        return document
    }

    /// Builds a device whose episodes each have a completed download with a
    /// known source identity, so a re-attached run reaches the poll leg.
    private func makeDevice(
        episodeIDs: [String],
        api: RemoteJobFaultInjectingAPI? = nil,
        fixture: RemoteJobRecoveryFixture? = nil
    ) async throws -> Device {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        let transcriptions = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        try downloadFileStore.prepareDownloadsDirectory()

        var episodes: [EpisodeListItemSnapshot] = []
        var identities: [String: OpenCastRemoteTranscriptionSourceIdentity] = [:]
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
            identities[episodeID] = identity
        }
        try context.save()
        await downloads.load(modelContext: context)

        let resolvedAPI: RemoteJobFaultInjectingAPI
        if let api {
            resolvedAPI = api
        } else if let fixture, let identity = episodeIDs.first.flatMap({ identities[$0] }) {
            resolvedAPI = fixture.makeAPI(resultResponse: OpenCastRemoteTranscriptionResultResponse(
                schemaVersion: 1,
                result: Self.result(identity: identity, durationSeconds: 120)
            ))
        } else {
            resolvedAPI = RemoteJobFaultInjectingAPI(pollScript: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing),
            ])
        }
        let suiteName = "remote-reattach-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return Device(
            api: resolvedAPI,
            defaults: defaults,
            diagnostics: RecordingRemoteJobDiagnosticSink(),
            transcriptions: transcriptions,
            downloads: downloads,
            context: context,
            episodes: episodes,
            identities: identities
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastRemoteReattachTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
