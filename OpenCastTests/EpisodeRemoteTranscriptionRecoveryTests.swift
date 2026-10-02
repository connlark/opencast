import CryptoKit
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// The recovery rows the runner and plain coordinator own, driven by the
/// fixture catalog's fault scripts: a create that never leaves or loses its
/// response keeps the same client request ID, only a user cancel reaches
/// `/cancel` (exactly once, after an in-flight create has attached), every
/// transport or local give-up keeps the attached reference for Resume, and
/// `acknowledged` reconciles against local provenance instead of rendering
/// as a server rejection.
@MainActor
@Suite("Remote transcription recovery", .serialized)
struct EpisodeRemoteTranscriptionRecoveryTests {
    @MainActor
    private struct Environment {
        var coordinator: EpisodeRemoteTranscriptionCoordinator
        var runner: RemoteTranscriptionJobRunner
        var api: RemoteJobFaultInjectingAPI
        var store: RemoteTranscriptionJobStore
        var diagnostics: RecordingRemoteJobDiagnosticSink
        var transcriptions: EpisodeTranscriptionStore
        var downloads: DownloadStore
        var context: ModelContext
        var episode: EpisodeListItemSnapshot
        var identity: OpenCastRemoteTranscriptionSourceIdentity

        func reference(_ purpose: RemoteTranscriptionJobPurpose = .transcription) -> RemoteTranscriptionJobReference? {
            store.existingReference(for: episode.episodeID, purpose: purpose)
        }
    }

    // MARK: Create and attach (CONTRACTS §3)

    @Test("A create that never leaves keeps a retryable reference, sends no cancel and reuses the same client request ID")
    func createNeverLeavesKeepsPreparedReference() async throws {
        let fixture = RemoteJobRecoveryFixture.createNeverLeaves
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-create-never-leaves")
        let api = environment.api

        await #expect(throws: RemoteTranscriptionJobRunError.connectionLost) {
            try await run(environment)
        }

        let reference = try #require(environment.reference())
        #expect(reference.createState == .createAttempted)
        #expect(reference.jobID == nil)
        #expect(reference.lastExit == .connectionLost)
        #expect(api.cancelCalls.isEmpty)
        #expect(api.mintedJobIDs.isEmpty)
        #expect(api.serverJobID(forClientRequestID: reference.clientRequestID) == nil)
        #expect(api.createCalls == [
            .init(leg: .create, clientRequestID: reference.clientRequestID, jobID: nil, reachedServer: false, responseDelivered: false),
        ])

        // Try Again repeats the same ID; the server mints exactly one job.
        try await runUntilAttached(environment)
        #expect(environment.reference()?.jobID == "job-fake-1")
        #expect(environment.reference()?.clientRequestID == reference.clientRequestID)
        #expect(api.createRequests.map(\.clientRequestID) == [reference.clientRequestID, reference.clientRequestID])
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(api.cancelCalls.isEmpty)
    }

    @Test("A lost create response re-attaches by the same client request ID and discovers exactly one job")
    func lostCreateResponseReattachesBySameClientID() async throws {
        let fixture = RemoteJobRecoveryFixture.createAcceptedResponseLost
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-create-lost")
        let api = environment.api

        await #expect(throws: RemoteTranscriptionJobRunError.connectionLost) {
            try await run(environment)
        }

        let reference = try #require(environment.reference())
        #expect(reference.createState == .createAttempted)
        #expect(reference.jobID == nil)
        #expect(api.serverJobID(forClientRequestID: reference.clientRequestID) == "job-fake-1")
        #expect(api.cancelCalls.isEmpty)
        #expect(environment.diagnostics.containsInOrder([.createAttempted, .legFailed, .createUncertain]))
        #expect(environment.diagnostics.events(of: .createUncertain).first?.disposition == .retained)
        #expect(environment.diagnostics.events(of: .createUncertain).first?.clientRequestID == reference.clientRequestID)

        try await runUntilAttached(environment)

        let attached = try #require(environment.reference())
        #expect(attached.clientRequestID == reference.clientRequestID)
        #expect(attached.jobID == "job-fake-1")
        #expect(attached.createState == .attached)
        #expect(api.createRequests.map(\.clientRequestID) == [reference.clientRequestID, reference.clientRequestID])
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(api.cancelCalls.isEmpty)
        let createAttached = environment.diagnostics.events(of: .createAttached)
        #expect(createAttached.last?.jobID == "job-fake-1")
        #expect(createAttached.last?.clientRequestID == reference.clientRequestID)
    }

    @Test("A landed create error clears the reference on the first attempt and keeps it on a repeated one")
    func landedCreateErrorDispositionByAttempt() async throws {
        let landed = RemoteTranscriptionHTTPError(statusCode: 429, code: "rate_limited", detail: nil)

        let first = try await makeEnvironment(api: RemoteJobFaultInjectingAPI(), episodeID: "ep-landed-first")
        first.api.inject(.landed(landed), at: .create)
        await #expect(throws: RemoteTranscriptionJobRunError.serverRejected(.rateLimited)) {
            try await run(first)
        }
        #expect(first.reference() == nil)
        #expect(first.api.mintedJobIDs.isEmpty)
        #expect(first.api.cancelCalls.isEmpty)

        let repeated = try await makeEnvironment(
            api: RemoteJobRecoveryFixture.createNeverLeaves.makeAPI(),
            episodeID: "ep-landed-repeated"
        )
        await #expect(throws: RemoteTranscriptionJobRunError.connectionLost) {
            try await run(repeated)
        }
        let attempted = try #require(repeated.reference())
        repeated.api.inject(.landed(landed), at: .create)
        await #expect(throws: RemoteTranscriptionJobRunError.serverRejected(.rateLimited)) {
            try await run(repeated)
        }
        let kept = try #require(repeated.reference())
        #expect(kept.createState == .createAttempted)
        #expect(kept.clientRequestID == attempted.clientRequestID)
        #expect(repeated.api.cancelCalls.isEmpty)
    }

    // MARK: Cancellation (CONTRACTS §4)

    @Test("A cancel before any create attempt clears the prepared reference without a server call")
    func cancelBeforeCreateClearsWithoutServerCall() async throws {
        let gate = RemoteJobFaultInjectingAPI.Gate()
        let api = RemoteJobFaultInjectingAPI()
        api.inject(.delayed(gate), at: .bootstrap)
        let environment = try await makeEnvironment(api: api, episodeID: "ep-cancel-before-create")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        // The runner mints the reference before its gated bootstrap suspends.
        #expect(await waitUntil { environment.reference() != nil })
        environment.coordinator.cancel()
        let intent = try #require(environment.reference())
        #expect(intent.userCancelRequestedAt != nil)
        #expect(intent.createState == .prepared)

        gate.release()
        await environment.coordinator.userCancelTask?.value

        #expect(environment.store.phase == .cancelled)
        #expect(environment.reference() == nil)
        #expect(api.createCalls.isEmpty)
        #expect(api.cancelCalls.isEmpty)
        #expect(api.mintedJobIDs.isEmpty)
    }

    @Test("A cancel during create persists intent first, lets the response attach, then sends exactly one cancel")
    func cancelDuringCreateSendsOneCancelAfterAttach() async throws {
        let gate = RemoteJobFaultInjectingAPI.Gate()
        let fixture = RemoteJobRecoveryFixture.createDelayedThenUserCancels
        let environment = try await makeEnvironment(api: fixture.makeAPI(gate: gate), episodeID: "ep-cancel-during-create")
        let api = environment.api

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { api.createRequests.count == 1 })
        #expect(!gate.isReleased)

        environment.coordinator.cancel()
        let intent = try #require(environment.reference())
        #expect(intent.userCancelRequestedAt != nil)
        #expect(intent.createState == .createAttempted)
        #expect(api.cancelCalls.isEmpty)

        gate.release()
        await environment.coordinator.userCancelTask?.value

        #expect(environment.store.phase == .cancelled)
        #expect(api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(api.serverState(of: "job-fake-1") == .cancelled)
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(environment.reference() == nil)
        #expect(environment.diagnostics.containsInOrder([.userCancelRequested, .createAttached, .cancelAttempted, .referenceCleared]))
        #expect(environment.diagnostics.events(of: .cancelAttempted).count == 1)
    }

    @Test("A cancel after a lost create response replays the same client request ID, then cancels once")
    func cancelAfterLostCreateReplaysSameIDThenCancelsOnce() async throws {
        let fixture = RemoteJobRecoveryFixture.createAcceptedResponseLost
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-cancel-after-lost-create")
        let api = environment.api

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { environment.store.phase == .parkedOnServer(.connectionLost) })
        let parked = try #require(environment.reference())
        #expect(parked.jobID == nil)

        environment.coordinator.cancel()
        await environment.coordinator.userCancelTask?.value

        #expect(environment.store.phase == .cancelled)
        #expect(api.createRequests.map(\.clientRequestID) == [parked.clientRequestID, parked.clientRequestID])
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(api.serverState(of: "job-fake-1") == .cancelled)
        #expect(environment.reference() == nil)
    }

    @Test("A lost cancel response keeps the intent, suppresses re-attach, and retries the same intent once per trigger")
    func lostCancelResponseKeepsIntentAndRetriesOnce() async throws {
        let fixture = RemoteJobRecoveryFixture.cancelResponseLost
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-cancel-lost")
        let api = environment.api

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { api.pollCalls.count >= 1 })

        environment.coordinator.cancel()
        await environment.coordinator.userCancelTask?.value

        #expect(environment.store.phase == .cancelled)
        #expect(api.cancelCalls == [
            .init(leg: .cancel, clientRequestID: nil, jobID: "job-fake-1", reachedServer: true, responseDelivered: false),
        ])
        #expect(api.serverState(of: "job-fake-1") == .cancelled)
        let retained = try #require(environment.reference())
        #expect(retained.userCancelRequestedAt != nil)
        #expect(retained.jobID == "job-fake-1")
        #expect(environment.diagnostics.containsInOrder([.userCancelRequested, .cancelUncertain]))

        // The persisted intent is never re-attached as an active job.
        let pollsBefore = api.pollCalls.count
        #expect(environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
            == .rejected("The previous remote transcription is still being cancelled."))
        await #expect(throws: CancellationError.self) {
            try await run(environment)
        }
        #expect(api.pollCalls.count == pollsBefore)

        // The next recovery trigger retries the same intent exactly once.
        let resolution = await environment.runner.cancelServerJob(episodeID: environment.episode.episodeID, purpose: .transcription)
        #expect(resolution == .cancelled(jobID: "job-fake-1"))
        #expect(api.cancelCalls.count == 2)
        #expect(environment.reference() == nil)
        #expect(environment.diagnostics.events(of: .cancelAttempted).count == 1)
    }

    // MARK: Exit dispositions (CONTRACTS §5)

    @Test("Transport give-up after attach keeps the attached reference with connectionLost and sends no cancel")
    func transportGiveUpKeepsReferenceWithoutCancel() async throws {
        let fixture = RemoteJobRecoveryFixture.transportAfterAttach
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-transport-after-attach")
        let api = environment.api

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { environment.store.phase == .parkedOnServer(.connectionLost) })

        let reference = try #require(environment.reference())
        #expect(reference.createState == .attached)
        #expect(reference.jobID == "job-fake-1")
        #expect(reference.lastExit == .connectionLost)
        #expect(api.cancelCalls.isEmpty)
        #expect(api.pollCalls.allSatisfy { !$0.reachedServer })
        #expect(!environment.store.hasActiveRequest)
        let presentation = try #require(RemoteTranscriptionStatusPresentation.make(phase: environment.store.phase))
        #expect(presentation.isParked)
        #expect(presentation.offersResume)
        #expect(!presentation.isTerminalFailure)
        #expect(environment.diagnostics.containsInOrder([.createAttached, .legFailed, .parked]))

        // Resume re-attaches the same job and polls it again.
        let createsBefore = api.createCalls.count
        environment.coordinator.resume(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { api.createCalls.count == createsBefore + 1 && api.pollCalls.last?.jobID == "job-fake-1" })
        #expect(await waitUntil { environment.store.phase == .parkedOnServer(.connectionLost) })
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(api.createRequests.map(\.clientRequestID) == [reference.clientRequestID, reference.clientRequestID])
        #expect(api.cancelCalls.isEmpty)
    }

    @Test("A local leg failure retries on the short ladder, then parks as localRequestFailed without a cancel")
    func localLegFailureParksWithoutCancel() async throws {
        let fixture = RemoteJobRecoveryFixture.localLegFailure
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-local-leg")
        let api = environment.api
        let runner = RemoteTranscriptionJobRunner(
            api: api,
            downloads: environment.downloads,
            transcriptions: environment.transcriptions,
            store: environment.store,
            transportRetryDelays: [],
            localRetryDelays: [.zero, .zero]
        )

        await #expect(throws: RemoteTranscriptionJobRunError.localRequestFailed) {
            _ = try await runner.run(
                episode: environment.episode,
                enclosureURL: environment.episode.audioURL!,
                purpose: .transcription,
                modelContext: environment.context,
                onEvent: { _ in }
            )
        }

        let reference = try #require(environment.reference())
        #expect(reference.createState == .attached)
        #expect(reference.jobID == "job-fake-1")
        #expect(reference.lastExit == .localRequestFailed)
        #expect(api.cancelCalls.isEmpty)
        #expect(api.pollCalls.count == 3)
        #expect(api.pollCalls.allSatisfy { !$0.reachedServer })
        #expect(api.serverState(of: "job-fake-1") == .created)
        let retried = environment.diagnostics.events(of: .legRetried).filter { $0.leg == .poll }
        #expect(retried.map(\.attempt) == [1, 2])
        #expect(retried.allSatisfy { $0.error?.domain == .keychain })
        #expect(environment.diagnostics.containsInOrder([.legRetried, .legRetried, .legFailed, .parked]))
        #expect(environment.diagnostics.events(of: .cancelAttempted).isEmpty)
        #expect(RemoteTranscriptionStatusPresentation.make(phase: .failed(.localRequestFailed))?.offersRetry == true)
    }

    @Test("A park keeps the attached reference without a cancel, and Resume re-attaches the same job")
    func parkKeepsReferenceAndResumeReattaches() async throws {
        let api = RemoteJobFaultInjectingAPI(pollScript: [OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing)])
        let environment = try await makeEnvironment(api: api, episodeID: "ep-park")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { api.pollCalls.count >= 1 })

        environment.coordinator.park(exit: .parked)
        #expect(await waitUntil { environment.store.phase == .parkedOnServer(.parked) })

        let reference = try #require(environment.reference())
        #expect(reference.createState == .attached)
        #expect(reference.jobID == "job-fake-1")
        #expect(reference.lastExit == .parked)
        #expect(reference.userCancelRequestedAt == nil)
        #expect(api.cancelCalls.isEmpty)
        #expect(api.serverState(of: "job-fake-1") == .transcribing)

        environment.coordinator.resume(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { api.createCalls.count == 2 && api.pollCalls.count >= 2 })
        #expect(api.mintedJobIDs == ["job-fake-1"])
        #expect(api.createRequests.map(\.clientRequestID) == [reference.clientRequestID, reference.clientRequestID])
        #expect(environment.reference()?.lastExit == nil)
        environment.coordinator.park(exit: .parked)
        #expect(await waitUntil { environment.store.phase == .parkedOnServer(.parked) })
        #expect(api.cancelCalls.isEmpty)
    }

    // MARK: Acknowledgement reconciliation (CONTRACTS §7)

    @Test("A re-run after death following import is idempotent, acks, and clears the reference")
    func importIsIdempotentAfterDeath() async throws {
        let fixture = RemoteJobRecoveryFixture.deathAfterImport
        let environment = try await makeEnvironment(api: nil, episodeID: "ep-death-after-import", fixture: fixture)
        let api = environment.api
        let seed = try #require(try fixture.seedPersistedState(
            store: environment.store, api: api, modelContext: environment.context, episode: environment.episode
        ))
        let imported = try await importDocument(environment, jobID: seed.jobID)
        let priorPath = try #require(environment.transcriptions.record(for: environment.episode.episodeID)?.transcriptRelativePath)

        let outcome = try await run(environment)

        #expect(outcome.jobID == seed.jobID)
        #expect(outcome.document.remoteJobProvenanceToken == seed.jobID)
        #expect(outcome.document.normalizedTranscriptSHA256 == imported.normalizedTranscriptSHA256)
        #expect(environment.transcriptions.record(for: environment.episode.episodeID)?.transcriptRelativePath == priorPath)
        #expect(environment.transcriptions.document(for: environment.episode.episodeID)?.remoteJobProvenanceToken == seed.jobID)
        #expect(api.createRequests.map(\.clientRequestID) == [seed.reference.clientRequestID])
        #expect(api.mintedJobIDs == [seed.jobID])
        #expect(api.ackCalls.map(\.jobID) == [seed.jobID])
        #expect(api.serverState(of: seed.jobID) == .acknowledged)
        #expect(api.cancelCalls.isEmpty)
        #expect(environment.reference() == nil)
        #expect(environment.diagnostics.containsInOrder([.imported, .acknowledged, .referenceCleared]))
    }

    @Test("An acknowledged poll with local provenance is success, never a server rejection")
    func acknowledgedWithProvenanceIsSuccess() async throws {
        let fixture = RemoteJobRecoveryFixture.deathAfterAck
        let environment = try await makeEnvironment(api: nil, episodeID: "ep-death-after-ack", fixture: fixture)
        let api = environment.api
        let seed = try #require(try fixture.seedPersistedState(
            store: environment.store, api: api, modelContext: environment.context, episode: environment.episode
        ))
        let imported = try await importDocument(environment, jobID: seed.jobID)

        let outcome = try await run(environment)

        #expect(outcome.jobID == seed.jobID)
        #expect(outcome.document.remoteJobProvenanceToken == seed.jobID)
        #expect(outcome.document.normalizedTranscriptSHA256 == imported.normalizedTranscriptSHA256)
        #expect(outcome.adAnalysis == nil)
        #expect(api.callSequence == [.bootstrap, .create, .source, .poll])
        #expect(api.resultCalls.isEmpty)
        #expect(api.ackCalls.isEmpty)
        #expect(api.cancelCalls.isEmpty)
        #expect(api.mintedJobIDs == [seed.jobID])
        #expect(environment.reference() == nil)
        #expect(environment.transcriptions.document(for: environment.episode.episodeID)?.remoteJobProvenanceToken == seed.jobID)
        #expect(environment.diagnostics.containsInOrder([.pollObserved, .acknowledged, .referenceCleared]))
        #expect(environment.diagnostics.events(of: .pollObserved).last?.serverState == .acknowledged)
        #expect(environment.diagnostics.events(of: .acknowledgedWithoutLocalImport).isEmpty)
    }

    @Test("An acknowledged poll without local provenance is a distinct terminal outcome, not a server rejection")
    func acknowledgedWithoutLocalImportIsDistinct() async throws {
        let fixture = RemoteJobRecoveryFixture.acknowledgedWithoutImport
        let environment = try await makeEnvironment(api: fixture.makeAPI(), episodeID: "ep-ack-without-import")
        let api = environment.api

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { environment.store.phase == .failed(.acknowledgedWithoutLocalImport) })

        #expect(environment.reference() == nil)
        #expect(api.resultCalls.isEmpty)
        #expect(api.cancelCalls.isEmpty)
        #expect(environment.transcriptions.document(for: environment.episode.episodeID) == nil)
        let presentation = try #require(RemoteTranscriptionStatusPresentation.make(phase: environment.store.phase))
        #expect(presentation.title == "Transcript wasn't saved on this device")
        #expect(presentation.isTerminalFailure)
        #expect(presentation.offersRetry)
        #expect(presentation.offersLocalFallback)
        #expect(presentation != RemoteTranscriptionStatusPresentation.make(phase: .failed(.serverRejected(.internalError))))
        #expect(environment.diagnostics.containsInOrder([.pollObserved, .acknowledgedWithoutLocalImport, .referenceCleared]))
        #expect(environment.diagnostics.events(of: .acknowledged).isEmpty)
    }

    // MARK: Review follow-ups (2026-09-26)

    @Test("A bootstrap give-up on a re-run is judged by the persisted create state, so an attached job parks as connectionLost")
    func bootstrapGiveUpOnResumeParksByPersistedCreateState() async throws {
        // Attached: park a live run, then lose the network before Resume's bootstrap.
        let attachedAPI = RemoteJobFaultInjectingAPI(
            pollScript: [OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing)]
        )
        let attached = try await makeEnvironment(api: attachedAPI, episodeID: "ep-resume-bootstrap-attached")
        attached.coordinator.start(episode: attached.episode, modelContext: attached.context)
        #expect(await waitUntil { attachedAPI.pollCalls.count >= 1 })
        attached.coordinator.park(exit: .parked)
        #expect(await waitUntil { attached.store.phase == .parkedOnServer(.parked) })
        #expect(attached.reference()?.createState == .attached)

        attachedAPI.inject(.neverLeaves(URLError(.notConnectedToInternet)), at: .bootstrap, times: .max)
        attached.coordinator.resume(episode: attached.episode, modelContext: attached.context)
        #expect(await waitUntil { attached.store.phase == .parkedOnServer(.connectionLost) })

        let stillAttached = try #require(attached.reference())
        #expect(stillAttached.createState == .attached)
        #expect(stillAttached.jobID == "job-fake-1")
        #expect(stillAttached.lastExit == .connectionLost)
        #expect(attachedAPI.createCalls.count == 1)
        #expect(attachedAPI.cancelCalls.isEmpty)
        #expect(RemoteTranscriptionStatusPresentation.make(phase: attached.store.phase)?.offersResume == true)
        #expect(attached.diagnostics.events(of: .legFailed).last?.leg == .bootstrap)

        // createAttempted without a job id: the create may have mapped, so the
        // same rule applies instead of the prepared-reference copy.
        let lostAPI = RemoteJobRecoveryFixture.createAcceptedResponseLost.makeAPI()
        let lost = try await makeEnvironment(api: lostAPI, episodeID: "ep-resume-bootstrap-lost")
        await #expect(throws: RemoteTranscriptionJobRunError.connectionLost) {
            try await run(lost)
        }
        #expect(lost.reference()?.createState == .createAttempted)

        lostAPI.inject(.neverLeaves(URLError(.notConnectedToInternet)), at: .bootstrap, times: .max)
        await #expect(throws: RemoteTranscriptionJobRunError.connectionLost) {
            try await run(lost)
        }
        let kept = try #require(lost.reference())
        #expect(kept.createState == .createAttempted)
        #expect(kept.lastExit == .connectionLost)
        #expect(lostAPI.createCalls.count == 1)
        #expect(lostAPI.cancelCalls.isEmpty)
    }

    @Test("Repeated cancel taps share one resolution and send exactly one cancel")
    func repeatedCancelTapsSendOneCancel() async throws {
        let gate = RemoteJobFaultInjectingAPI.Gate()
        let api = RemoteJobFaultInjectingAPI(
            pollScript: [OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing)]
        )
        api.inject(.delayed(gate), at: .cancel)
        let environment = try await makeEnvironment(api: api, episodeID: "ep-cancel-twice")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { api.pollCalls.count >= 1 })

        environment.coordinator.cancel()
        let firstCancel = try #require(environment.coordinator.userCancelTask)
        environment.coordinator.cancel()
        #expect(environment.coordinator.userCancelTask == firstCancel)
        // The run unwinds to the cancelled phase while the one cancel waits
        // at the gate; a tap in that window is a no-op as well.
        #expect(await waitUntil { environment.store.phase == .cancelled })
        environment.coordinator.cancel()
        #expect(!gate.isReleased)
        #expect(api.cancelCalls.isEmpty)

        gate.release()
        await firstCancel.value

        #expect(environment.store.phase == .cancelled)
        #expect(api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(api.serverState(of: "job-fake-1") == .cancelled)
        #expect(environment.reference() == nil)
        #expect(environment.diagnostics.events(of: .cancelAttempted).count == 1)
    }

    @Test("Concurrent cancel resolutions for one reference share a single cancel")
    func concurrentCancelResolutionsShareOneCancel() async throws {
        let gate = RemoteJobFaultInjectingAPI.Gate()
        let api = RemoteJobFaultInjectingAPI(
            pollScript: [OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .transcribing)]
        )
        api.inject(.delayed(gate), at: .cancel)
        let environment = try await makeEnvironment(api: api, episodeID: "ep-cancel-concurrent")
        try await runUntilAttached(environment)
        let episodeID = environment.episode.episodeID

        let first = Task { await environment.runner.cancelServerJob(episodeID: episodeID, purpose: .transcription) }
        let second = Task { await environment.runner.cancelServerJob(episodeID: episodeID, purpose: .transcription) }
        #expect(await waitUntil { environment.diagnostics.events(of: .userCancelRequested).count >= 1 })
        #expect(api.cancelCalls.isEmpty)

        gate.release()
        let resolutions = await [first.value, second.value]

        #expect(resolutions == [.cancelled(jobID: "job-fake-1"), .cancelled(jobID: "job-fake-1")])
        #expect(api.cancelCalls.map(\.jobID) == ["job-fake-1"])
        #expect(environment.diagnostics.events(of: .cancelAttempted).count == 1)
        #expect(environment.reference() == nil)

        // A later trigger on the cleared reference is a plain no-server-job answer, not a stale join.
        #expect(await environment.runner.cancelServerJob(episodeID: episodeID, purpose: .transcription) == .noServerJob)
        #expect(api.cancelCalls.count == 1)
    }

    @Test("A cancel that lands after the durable import completes the run: no cancel is sent, the reference clears, and the phase stays completed")
    func cancelAfterDurableImportCompletesTheRun() async throws {
        let gate = RemoteJobFaultInjectingAPI.Gate()
        let environment = try await makeEnvironment(api: nil, episodeID: "ep-cancel-during-ack", fixture: .deathAfterImport)
        let api = environment.api
        api.inject(.delayed(gate), at: .ack)

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil { environment.diagnostics.events(of: .imported).count == 1 })
        #expect(!gate.isReleased)
        #expect(environment.store.phase == .saving)

        environment.coordinator.cancel()
        #expect(environment.reference()?.userCancelRequestedAt != nil)

        gate.release()
        await environment.coordinator.userCancelTask?.value

        #expect(environment.store.phase == .completed)
        #expect(!environment.store.hasActiveRequest)
        #expect(api.ackCalls.map(\.jobID) == ["job-fake-1"])
        #expect(api.cancelCalls.isEmpty)
        #expect(api.serverState(of: "job-fake-1") == .acknowledged)
        #expect(environment.reference() == nil)
        #expect(environment.transcriptions.document(for: environment.episode.episodeID)?.remoteJobProvenanceToken == "job-fake-1")
        #expect(environment.diagnostics.containsInOrder([.imported, .userCancelRequested, .acknowledged, .referenceCleared]))
        #expect(environment.diagnostics.events(of: .cancelAttempted).isEmpty)
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ environment: Environment) async throws -> RemoteTranscriptionJobRunOutcome {
        try await environment.runner.run(
            episode: environment.episode,
            enclosureURL: environment.episode.audioURL!,
            purpose: .transcription,
            modelContext: environment.context,
            onEvent: { _ in }
        )
    }

    /// Runs the episode until its reference is attached, then cancels the
    /// local task (a park, never a server decision).
    private func runUntilAttached(_ environment: Environment) async throws {
        let task = Task { try await run(environment) }
        #expect(await waitUntil { environment.reference()?.createState == .attached })
        task.cancel()
        _ = try? await task.value
    }

    private func importDocument(_ environment: Environment, jobID: String) async throws -> EpisodeTranscriptDocument {
        let document = try EpisodeRemoteTranscriptMapper.document(
            from: Self.result(identity: environment.identity, durationSeconds: 120),
            context: EpisodeRemoteTranscriptMapper.Context(
                episodeID: environment.episode.episodeID,
                podcastID: environment.episode.podcastID,
                sourceAudioURL: environment.episode.audioURL!,
                localIdentity: environment.identity,
                jobProvenanceToken: jobID
            )
        )
        try await environment.transcriptions.importRemoteTranscript(document, modelContext: environment.context)
        return document
    }

    private func makeEnvironment(
        api: RemoteJobFaultInjectingAPI?,
        episodeID: String,
        fixture: RemoteJobRecoveryFixture? = nil
    ) async throws -> Environment {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        let transcriptions = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let episode = EpisodeListItemSnapshot.fixture(
            episodeID: episodeID,
            duration: 120,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: "https://example.com/art.jpg",
            guid: episodeID
        )

        let sourceURL = URL(string: episode.audioURL!)!
        let relativePath = downloadFileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
        let fileURL = downloadFileStore.fileURL(relativePath: relativePath)
        let data = Data("remote audio bytes \(episodeID)".utf8)
        try downloadFileStore.prepareDownloadsDirectory()
        try data.write(to: fileURL, options: .atomic)
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

        let resolvedAPI = try api ?? #require(fixture).makeAPI(
            resultResponse: OpenCastRemoteTranscriptionResultResponse(
                schemaVersion: 1,
                result: Self.result(identity: identity, durationSeconds: 120)
            )
        )
        let suiteName = "remote-recovery-tests-\(episodeID)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let diagnostics = RecordingRemoteJobDiagnosticSink()
        let store = RemoteTranscriptionJobStore(defaults: defaults, diagnostics: diagnostics)
        let coordinator = EpisodeRemoteTranscriptionCoordinator(
            api: resolvedAPI,
            downloads: downloads,
            transcriptions: transcriptions,
            store: store,
            transportRetryDelays: [],
            localRetryDelays: []
        )
        let runner = RemoteTranscriptionJobRunner(
            api: resolvedAPI,
            downloads: downloads,
            transcriptions: transcriptions,
            store: store,
            transportRetryDelays: [],
            localRetryDelays: []
        )
        return Environment(
            coordinator: coordinator,
            runner: runner,
            api: resolvedAPI,
            store: store,
            diagnostics: diagnostics,
            transcriptions: transcriptions,
            downloads: downloads,
            context: context,
            episode: episode,
            identity: identity
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastRemoteRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
