import CryptoKit
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// Local completion delivery for both remote flows. A run snapshots its
/// reference's delivery owner before the runner clears the reference, so an
/// outcome still knows its owner after cleanup. A remote owner suppresses
/// the completion, never the paused notification. Delivery is decided once
/// per run ending, at scheduling time: an active scene, missing
/// authorization or a silent ending never reaches `add`.
///
/// Nothing in production writes a remote owner yet; these tests plant one on
/// the reference the way a server-push client will.
@MainActor
@Suite("Remote job completion delivery", .serialized)
struct RemoteJobCompletionDeliveryTests {
    enum Script {
        /// The server keeps transcribing.
        case running
        /// The server delivers a result on the first poll.
        case delivers
        /// The server fails the job: the runner clears the reference, then
        /// throws.
        case serverFails
        /// Every poll loses the connection after attach.
        case connectionLost
    }

    @MainActor
    private struct Device {
        let api: RemoteJobFaultInjectingAPI
        let defaults: UserDefaults
        let diagnostics: RecordingRemoteJobDiagnosticSink
        let downloads: DownloadStore
        let transcriptions: EpisodeTranscriptionStore
        let adAnalyses: EpisodeAdAnalysisStore
        let context: ModelContext
        let episode: EpisodeListItemSnapshot

        /// Persisted state an earlier process wrote, with a throwaway sink.
        var seedStore: RemoteTranscriptionJobStore {
            RemoteTranscriptionJobStore(defaults: defaults, diagnostics: RecordingRemoteJobDiagnosticSink())
        }

        func reference(_ purpose: RemoteTranscriptionJobPurpose) -> RemoteTranscriptionJobReference? {
            seedStore.existingReference(for: episode.episodeID, purpose: purpose)
        }

        /// Plants a prepared reference whose completion a remote owner
        /// delivers.
        func seedRemoteOwner(_ purpose: RemoteTranscriptionJobPurpose) throws {
            let store = seedStore
            _ = store.reference(for: episode.episodeID, purpose: purpose)
            let references = store.references().map { reference in
                var reference = reference
                if reference.episodeID == episode.episodeID, reference.resolvedPurpose == purpose {
                    reference.completionDeliveryOwner = .remote
                }
                return reference
            }
            defaults.set(try JSONEncoder().encode(references), forKey: "remoteTranscription.jobReferences")
        }

        func makeCoordinator() -> EpisodeRemoteTranscriptionCoordinator {
            EpisodeRemoteTranscriptionCoordinator(
                api: api,
                downloads: downloads,
                transcriptions: transcriptions,
                store: RemoteTranscriptionJobStore(defaults: defaults, diagnostics: diagnostics),
                transportRetryDelays: [],
                localRetryDelays: []
            )
        }

        func deliveryEvents() -> [RemoteJobDiagnosticEvent] {
            diagnostics.events.filter { $0.component == .completionDelivery }
        }
    }

    @MainActor
    private struct AppRig {
        let appModel: OpenCastAppModel
        let center: FakeAdFreePassNotificationCenter
        let remoteScheduler: FakeAdFreePassContinuedTaskScheduler
        let adFreeScheduler: FakeAdFreePassContinuedTaskScheduler

        var phase: RemoteTranscriptionRequestPhase? {
            appModel.remoteTranscription.store.phase
        }

        /// True when a further notification shows up within a short window
        /// after the one the test expected.
        func postsAnotherNotification(beyond count: Int) async -> Bool {
            await waitUntil(timeout: .milliseconds(400)) { center.addedRequests.count > count }
        }
    }

    // MARK: Ownership survives the cleanup (fixture ownerBeforeClear)

    @Test(
        "The run outcome carries the owner it snapshotted before the reference was cleared, and delivery filters on it",
        arguments: [JobCompletionDeliveryOwner.local, .remote]
    )
    func outcomeCarriesOwnerAfterReferenceClear(owner: JobCompletionDeliveryOwner) async throws {
        let device = try await makeDevice(episodeID: "ep-owner-\(owner.rawValue)", script: .delivers)
        if owner == .remote {
            try device.seedRemoteOwner(.transcription)
        }
        let runner = RemoteTranscriptionJobRunner(
            api: device.api,
            downloads: device.downloads,
            transcriptions: device.transcriptions,
            store: RemoteTranscriptionJobStore(defaults: device.defaults, diagnostics: device.diagnostics),
            transportRetryDelays: [],
            localRetryDelays: []
        )

        let outcome = try await runner.run(
            episode: device.episode,
            enclosureURL: try #require(device.episode.audioURL),
            purpose: .transcription,
            modelContext: device.context,
            onEvent: { _ in }
        )

        #expect(outcome.completionDeliveryOwner == owner)
        // The reference was gone before the outcome reached the caller.
        #expect(device.reference(.transcription) == nil)
        #expect(device.api.serverState(of: outcome.jobID) == .acknowledged)

        let center = FakeAdFreePassNotificationCenter()
        let decision = await RemoteTranscriptionNotificationScheduler(center: center).scheduleIfNeeded(
            phase: .completed,
            episodeTitle: device.episode.title,
            deliveryOwner: outcome.completionDeliveryOwner,
            isSceneActive: false
        )
        let expected: CompletionDeliveryDecision = owner == .remote ? .suppressed(.remoteOwner) : .scheduled
        #expect(decision == expected)
        #expect(center.addedRequests.count == (owner == .remote ? 0 : 1))

        let summary = AdFreePassCompletionNotificationContent(
            terminal: .drained(completedCount: 1, failedCount: 0),
            outcomes: [AdFreePassQueueItemOutcome(
                episodeID: device.episode.episodeID,
                episodeTitle: device.episode.title,
                artworkURL: nil,
                kind: .completed(zoneCount: 2),
                completionDeliveryOwner: outcome.completionDeliveryOwner
            )]
        )
        #expect((summary == nil) == (owner == .remote))
    }

    @Test("A plain run that the server fails clears the reference before it throws, and its run ending still carries the owner")
    func plainFailureCarriesOwnerSnapshot() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-fails", script: .serverFails)
        try device.seedRemoteOwner(.transcription)
        let coordinator = device.makeCoordinator()
        var endings: [(phase: RemoteTranscriptionRequestPhase, owner: JobCompletionDeliveryOwner)] = []
        coordinator.onRunEnded = { _, phase, owner in endings.append((phase, owner)) }

        #expect(coordinator.start(episode: device.episode, modelContext: device.context) == .started)

        #expect(await waitUntil { !endings.isEmpty && !coordinator.store.hasActiveRequest })
        #expect(endings.count == 1)
        #expect(endings.first?.phase == .failed(.serverRejected(.internalError)))
        #expect(endings.first?.owner == .remote)
        #expect(device.reference(.transcription) == nil)
    }

    @Test(
        "A cloud item the server fails keeps its owner on the queue outcome after the clear; a remote-owned drain stays silent",
        arguments: [JobCompletionDeliveryOwner.local, .remote]
    )
    func cloudFailureCarriesOwnerSnapshot(owner: JobCompletionDeliveryOwner) async throws {
        let device = try await makeDevice(episodeID: "ep-cloud-fails-\(owner.rawValue)", script: .serverFails)
        if owner == .remote {
            try device.seedRemoteOwner(.adDetection)
        }
        let rig = makeAppModel(device, isSceneActive: false)

        rig.appModel.startAdFreePass(for: device.episode, modelContext: device.context, mode: .cloud)

        #expect(await waitUntil {
            rig.appModel.adFreePass.queueState == .idle && !rig.appModel.adFreePass.drainOutcomes.isEmpty
        })
        let outcome = try #require(rig.appModel.adFreePass.drainOutcomes.first)
        #expect(outcome.completionDeliveryOwner == owner)
        #expect(device.reference(.adDetection) == nil)

        switch owner {
        case .remote:
            #expect(await waitUntil {
                device.deliveryEvents().contains { $0.disposition == .suppressedRemoteOwner }
            })
            let event = try #require(device.deliveryEvents().first)
            #expect(device.deliveryEvents().count == 1)
            #expect(event.kind == .notificationSuppressed)
            #expect(event.episodeID == device.episode.episodeID)
            #expect(event.purpose == .adDetection)
            #expect(await rig.postsAnotherNotification(beyond: 0) == false)
        case .local:
            #expect(await waitUntil { rig.center.addedRequests.count == 1 })
            #expect(rig.center.addedRequests.first?.content.title == "Ad detection finished")
            #expect(device.deliveryEvents().isEmpty)
        }
    }

    // MARK: Plain completion

    @Test(
        "A plain completion posts one Transcript ready notification only while the scene is not active",
        arguments: [false, true]
    )
    func plainCompletionHonorsTheSceneGate(isSceneActive: Bool) async throws {
        let device = try await makeDevice(episodeID: "ep-plain-done-\(isSceneActive)", script: .delivers)
        let rig = makeAppModel(device, isSceneActive: isSceneActive)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)

        #expect(await waitUntil { rig.phase == .completed })
        #expect(await waitUntil { !device.deliveryEvents().isEmpty })
        let event = try #require(device.deliveryEvents().first)
        #expect(device.deliveryEvents().count == 1)
        #expect(event.episodeID == device.episode.episodeID)
        #expect(event.purpose == .transcription)
        if isSceneActive {
            #expect(event.kind == .notificationSuppressed)
            #expect(event.disposition == .suppressedSceneActive)
            #expect(rig.center.addedRequests.isEmpty)
            // The one read is the arm's provisional-authorization check;
            // delivery never reached authorization.
            #expect(rig.center.authorizationStatusReadCount == 1)
        } else {
            #expect(event.kind == .notificationScheduled)
            let request = try #require(rig.center.addedRequests.first)
            #expect(rig.center.addedRequests.count == 1)
            #expect(request.content.title == "Transcript ready")
            #expect(request.content.body == "Remote Episode")
            #expect(request.content.threadIdentifier == RemoteTranscriptionNotificationScheduler.threadIdentifier)
            #expect(await rig.postsAnotherNotification(beyond: 1) == false)
        }
    }

    @Test("A plain failure in the background posts the status card's failure copy")
    func plainFailureNotifies() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-failure-notifies", script: .serverFails)
        let rig = makeAppModel(device, isSceneActive: false)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)

        #expect(await waitUntil { rig.phase == .failed(.serverRejected(.internalError)) })
        #expect(await waitUntil { rig.center.addedRequests.count == 1 })
        let request = try #require(rig.center.addedRequests.first)
        #expect(request.content.title == "Remote transcription didn't finish")
        #expect(request.content.body == RemoteTranscriptionFailureCategory.serverRejected(.internalError).message)
        #expect(request.content.threadIdentifier == RemoteTranscriptionNotificationScheduler.threadIdentifier)
        #expect(await waitUntil { !device.deliveryEvents().isEmpty })
        #expect(device.deliveryEvents().map(\.kind) == [.notificationScheduled])
        #expect(await rig.postsAnotherNotification(beyond: 1) == false)
    }

    @Test("A remote-owned plain completion stays local-silent and records the owner")
    func remoteOwnedPlainCompletionIsSuppressed() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-remote", script: .delivers)
        try device.seedRemoteOwner(.transcription)
        let rig = makeAppModel(device, isSceneActive: false)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)

        #expect(await waitUntil { rig.phase == .completed })
        #expect(await waitUntil { !device.deliveryEvents().isEmpty })
        #expect(device.reference(.transcription) == nil)
        let event = try #require(device.deliveryEvents().first)
        #expect(event.kind == .notificationSuppressed)
        #expect(event.disposition == .suppressedRemoteOwner)
        #expect(rig.center.addedRequests.isEmpty)
        // The one read is the arm's provisional-authorization check;
        // delivery never reached authorization.
        #expect(rig.center.authorizationStatusReadCount == 1)
    }

    // MARK: Plain park

    @Test("Expiration during bootstrap posts device-paused copy and preserves the request for Resume")
    func expirationBeforeCreateDoesNotClaimServerWork() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-expire-bootstrap", script: .running)
        let bootstrapGate = RemoteJobFaultInjectingAPI.Gate()
        defer { bootstrapGate.release() }
        device.api.inject(.delayed(bootstrapGate), at: .bootstrap)
        let rig = makeAppModel(device, isSceneActive: false)
        let handle = FakeAdFreePassContinuedTaskHandle()

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)
        #expect(await waitUntil { bootstrapGate.isHoldingRequest })
        let reference = try #require(device.reference(.transcription))
        #expect(reference.createState == .prepared)
        rig.remoteScheduler.launch(handle)
        handle.expire()
        bootstrapGate.release()

        #expect(await waitUntil { rig.phase == .parkedOnServer(.parked) })
        #expect(await waitUntil { rig.center.addedRequests.count == 1 })
        let request = try #require(rig.center.addedRequests.first)
        #expect(request.content.title == "Remote transcription paused")
        #expect(request.content.body == "The server job hasn't started. Open OpenCast and resume to try again.")
        #expect(device.api.createCalls.isEmpty)
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.reference(.transcription)?.createState == .prepared)
        #expect(device.reference(.transcription)?.clientRequestID == reference.clientRequestID)
        #expect(device.deliveryEvents().map(\.kind) == [.notificationScheduled])

        rig.appModel.isSceneActive = true
        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        #expect(device.reference(.transcription)?.clientRequestID == reference.clientRequestID)
        await parkPlain(rig)
    }

    @Test("An expiration park posts one paused notification, even for a remote owner, and a late park adds nothing")
    func expirationParkPostsOnePausedNotification() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-expire", script: .running)
        try device.seedRemoteOwner(.transcription)
        let rig = makeAppModel(device, isSceneActive: false)
        let handle = FakeAdFreePassContinuedTaskHandle()

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.remoteScheduler.launch(handle)
        handle.expire()
        handle.expire()

        #expect(await waitUntil { rig.phase == .parkedOnServer(.parked) })
        #expect(await waitUntil { rig.center.addedRequests.count == 1 })
        rig.appModel.remoteTranscription.park(exit: .parked)

        let request = try #require(rig.center.addedRequests.first)
        #expect(request.content.title == "Still running on the server")
        #expect(request.content.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.transcription)
        #expect(await rig.postsAnotherNotification(beyond: 1) == false)
        #expect(device.deliveryEvents().map(\.kind) == [.notificationScheduled])
        #expect(device.deliveryEvents().first?.jobID == "job-fake-1")
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.reference(.transcription)?.lastExit == .parked)
    }

    @Test("An expiration park schedules its paused notification before the system task completes")
    func expirationParkSchedulesBeforeTheTaskCompletes() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-expire-order", script: .running)
        let rig = makeAppModel(device, isSceneActive: false)
        let handle = FakeAdFreePassContinuedTaskHandle()
        var addsWhenCompleted: Int?
        var deliveryEventsWhenCompleted: Int?
        handle.onCompleted = { _ in
            addsWhenCompleted = rig.center.addedRequests.count
            deliveryEventsWhenCompleted = device.deliveryEvents().count
        }

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.remoteScheduler.launch(handle)
        handle.expire()

        #expect(await waitUntil { handle.completions == [false] })
        // On a locked phone iOS suspends the app as soon as the task
        // completes, so the run ending and its notification must already be
        // delivered by then (SANDBOX SE, 2026-10-05: they arrived on unlock).
        #expect(addsWhenCompleted == 1)
        #expect(deliveryEventsWhenCompleted == 1)
        #expect(rig.phase == .parkedOnServer(.parked))
        #expect(device.diagnostics.containsInOrder([
            .sessionExpired, .parked, .runEnded, .notificationScheduled, .sessionCompleted,
        ]))
        #expect(rig.center.addedRequests.first?.content.title == "Still running on the server")
        #expect(device.api.cancelCalls.isEmpty)
        #expect(device.reference(.transcription)?.lastExit == .parked)
    }

    @Test("Two parks before the run unwinds end the run once, with one paused notification")
    func doubleParkEndsTheRunOnce() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-double-park", script: .running)
        let rig = makeAppModel(device, isSceneActive: false)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.appModel.remoteTranscription.park(exit: .parked)
        rig.appModel.remoteTranscription.park(exit: .parked)

        #expect(await waitUntil { rig.phase == .parkedOnServer(.parked) && !rig.appModel.remoteTranscription.store.hasActiveRequest })
        #expect(await waitUntil { rig.center.addedRequests.count == 1 })
        #expect(await rig.postsAnotherNotification(beyond: 1) == false)
        #expect(device.deliveryEvents().map(\.kind) == [.notificationScheduled])
    }

    @Test("A connection-loss park ends the run as parked and stays silent")
    func connectionLossParkIsSilent() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-connection", script: .connectionLost)
        let coordinator = device.makeCoordinator()
        var endings: [(phase: RemoteTranscriptionRequestPhase, owner: JobCompletionDeliveryOwner)] = []
        coordinator.onRunEnded = { _, phase, owner in endings.append((phase, owner)) }

        #expect(coordinator.start(episode: device.episode, modelContext: device.context) == .started)

        #expect(await waitUntil { !endings.isEmpty })
        let ending = try #require(endings.first)
        #expect(ending.phase == .parkedOnServer(.connectionLost))
        let center = FakeAdFreePassNotificationCenter()
        let decision = await RemoteTranscriptionNotificationScheduler(center: center).scheduleIfNeeded(
            phase: ending.phase,
            episodeTitle: device.episode.title,
            deliveryOwner: ending.owner,
            isSceneActive: false
        )
        #expect(decision == .suppressed(.silentOutcome))
        #expect(center.addedRequests.isEmpty)
        #expect(device.reference(.transcription)?.lastExit == .connectionLost)
        #expect(device.api.cancelCalls.isEmpty)
    }

    @Test("A park that lands during a user cancel never posts paused copy for the cancelled job")
    func parkDuringUserCancelStaysSilent() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-cancel-park", script: .running)
        let rig = makeAppModel(device, isSceneActive: false)

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.appModel.remoteTranscription.cancel()
        rig.appModel.remoteTranscription.park(exit: .parked)
        await rig.appModel.remoteTranscription.userCancelTask?.value

        #expect(rig.phase == .cancelled)
        #expect(device.api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(device.reference(.transcription) == nil)
        #expect(await waitUntil { !device.deliveryEvents().isEmpty })
        #expect(device.deliveryEvents().map(\.disposition) == [.suppressedSilentOutcome])
        #expect(await rig.postsAnotherNotification(beyond: 0) == false)
    }

    @Test("Arming the remote card asks for provisional notification authorization")
    func armingRequestsProvisionalAuthorization() async throws {
        let device = try await makeDevice(episodeID: "ep-plain-arm-auth", script: .running)
        let rig = makeAppModel(device, isSceneActive: true)
        rig.center.authorizationStatusValue = .notDetermined

        #expect(rig.appModel.resumeRemoteTranscription(episode: device.episode, modelContext: device.context) == .started)

        #expect(rig.appModel.remoteTranscriptionBackgroundSession.isArmed)
        #expect(await waitUntil { rig.center.provisionalRequestCount == 1 })
        await parkPlain(rig)
    }

    // MARK: Cloud terminals

    @Test("An expiration park of a cloud item posts the server-still-working copy, never the device-paused copy")
    func cloudExpirationParkPostsServerCopy() async throws {
        let device = try await makeDevice(episodeID: "ep-cloud-expire", script: .running)
        let rig = makeAppModel(device, isSceneActive: false)
        let handle = FakeAdFreePassContinuedTaskHandle()

        rig.appModel.startAdFreePass(for: device.episode, modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.adFreeScheduler.launch(handle)
        handle.expire()

        #expect(await waitUntil {
            rig.appModel.adFreePass.queueStatus(for: device.episode.episodeID) == .remoteParked(.parked)
        })
        #expect(await waitUntil { rig.center.addedRequests.count == 1 })
        let request = try #require(rig.center.addedRequests.first)
        #expect(request.content.title == "Still running on the server")
        #expect(request.content.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))
        #expect(request.content.title != "Ad detection paused")
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.adFreePass)
        #expect(request.content.threadIdentifier == AdFreePassCompletionNotificationScheduler.threadIdentifier)
        #expect(await waitUntil { !device.deliveryEvents().isEmpty })
        let event = try #require(device.deliveryEvents().first)
        #expect(event.kind == .notificationScheduled)
        #expect(event.purpose == .adDetection)
        #expect(event.episodeID == device.episode.episodeID)
        #expect(event.jobID == "job-fake-1")
        #expect(device.api.cancelCalls.isEmpty)
        #expect(await rig.postsAnotherNotification(beyond: 1) == false)
        rig.appModel.adFreePass.reset()
    }

    @Test("A cloud user cancel ends silently, even with the scene inactive")
    func cloudUserCancelIsSilent() async throws {
        let device = try await makeDevice(episodeID: "ep-cloud-cancel", script: .running)
        let rig = makeAppModel(device, isSceneActive: false)

        rig.appModel.startAdFreePass(for: device.episode, modelContext: device.context, mode: .cloud)
        #expect(await waitUntil { device.api.pollCalls.count >= 1 })
        rig.appModel.adFreePass.cancelActivePass()

        #expect(await waitUntil { device.reference(.adDetection) == nil })
        #expect(await waitUntil { rig.appModel.adFreePass.queueState == .idle })
        #expect(device.api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(await rig.postsAnotherNotification(beyond: 0) == false)
        // The one read is the arm's provisional-authorization check; the
        // silent terminal never reached authorization.
        #expect(rig.center.authorizationStatusReadCount == 1)
    }

    // MARK: Helpers

    private func parkPlain(_ rig: AppRig) async {
        rig.appModel.remoteTranscription.park(exit: .parked)
        _ = await waitUntil { rig.appModel.remoteTranscription.store.hasActiveRequest == false }
    }

    private func makeAppModel(_ device: Device, isSceneActive: Bool) -> AppRig {
        let center = FakeAdFreePassNotificationCenter()
        let remoteScheduler = FakeAdFreePassContinuedTaskScheduler()
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
            remoteTranscriptionBackgroundSession: EpisodeRemoteTranscriptionBackgroundSession(scheduler: remoteScheduler),
            allowsAutomaticFeedRefresh: false,
            adFreePassNotificationCenter: center
        )
        appModel.configureBackgroundSessionExpirations(modelContext: device.context)
        appModel.isSceneActive = isSceneActive
        return AppRig(
            appModel: appModel,
            center: center,
            remoteScheduler: remoteScheduler,
            adFreeScheduler: adFreeScheduler
        )
    }

    /// One episode with a completed download of known identity, so a run
    /// reaches the poll leg, and a fake server running `script`.
    private func makeDevice(episodeID: String, script: Script) async throws -> Device {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        try downloadFileStore.prepareDownloadsDirectory()

        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: episodeID,
            title: "Remote Episode",
            duration: 120,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: "https://example.com/art.jpg",
            guid: episodeID
        )
        let audioURL = try #require(episode.audioURL)
        let sourceURL = try #require(URL(string: audioURL))
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
        try context.save()
        await downloads.load(modelContext: context)

        let api = switch script {
        case .running:
            RemoteJobFaultInjectingAPI(pollScript: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing),
            ])
        case .delivers:
            RemoteJobRecoveryFixture.ownerBeforeClear.makeAPI(
                resultResponse: OpenCastRemoteTranscriptionResultResponse(
                    schemaVersion: 1,
                    result: Self.result(identity: identity, durationSeconds: 120)
                )
            )
        case .serverFails:
            RemoteJobFaultInjectingAPI(pollScript: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .failed),
            ])
        case .connectionLost:
            RemoteJobRecoveryFixture.transportAfterAttach.makeAPI()
        }
        let suiteName = "remote-completion-delivery-tests-\(UUID().uuidString)"
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
            episode: episode
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastRemoteCompletionDeliveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
