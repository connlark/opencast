import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData
import Synchronization
import Testing
@testable import OpenCast

@MainActor
@Suite("Chapters & Summary run producer")
struct ChaptersSummaryRunProducerTests {
    @Test("A direct run writes its record before the send and closes it only after the document is installed")
    func directRunClosesAfterFinish() async throws {
        let harness = try Harness()
        let transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        harness.transport = transport
        let request = harness.request()

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .completed(let response, let completion) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        #expect(response.chapters.map(\.title) == ["Part One", "Part Two"])
        #expect(response.policy == EpisodeTranscriptAnalysisContract.expectedPolicy)
        #expect(response.requestID == request.runID)
        #expect(transport.recordStateAtSend == [.dispatched])
        // The answer is in but the document is not: the run stays
        // resumable with its kept reply.
        #expect(harness.runs.record(id: request.runID)?.state == .dispatched)

        harness.producer.finish(completion)

        let record = try #require(harness.runs.record(id: request.runID))
        #expect(record.state == .finished)
        #expect(record.outcomeCode == "completed")
        #expect(record.route == .direct)
        #expect(record.provider == .google)
        #expect(record.episodeID == request.episodeID)
        #expect(record.inputTokens == 420)
        #expect(record.outputTokens == 36)
        #expect(harness.usage == [UsageCall(provider: .google, input: 420, output: 36, runID: request.runID)])
        #expect(harness.presented.isEmpty)
    }

    @Test("A run held by an armed card reports that it finished in the background")
    func armedCardReportsBackground() async throws {
        let harness = try Harness()
        harness.scheduler.launchesOnSubmit = true
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .success)

        let result = await harness.producer.run(harness.request(), modelContext: harness.context)

        guard case .completed(_, let completion) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        #expect(completion.background)
        #expect(harness.scheduler.submitted == [AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier])
        harness.producer.finish(completion)
        #expect(harness.runs.record(id: completion.runID)?.background == true)
    }

    @Test("A refused card runs in the foreground only")
    func refusedCardRunsForegroundOnly() async throws {
        let harness = try Harness()
        harness.arbiter.otherCardArmed = { true }
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .success)

        let result = await harness.producer.run(harness.request(), modelContext: harness.context)

        guard case .completed(_, let completion) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        #expect(!completion.background)
        #expect(harness.scheduler.submitted.isEmpty)
    }

    @Test("Key required at resolution shows the key screen for a Generate tap, never for a resume")
    func keyRequiredAtResolution() async throws {
        let harness = try Harness()
        harness.resolution = .keyRequired(.trialExhausted, feature: .chaptersSummary)

        let result = await harness.producer.run(harness.request(), modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == .keyRequiredTrialExhausted)
        #expect(harness.presented == [.trialExhausted])
        #expect(harness.runs.records(limit: 10).isEmpty)

        let resumed = harness.request(isResume: true)
        try harness.runs.begin(harness.record(for: resumed))
        _ = await harness.producer.run(resumed, modelContext: harness.context)
        #expect(harness.presented == [.trialExhausted])
        #expect(harness.runs.record(id: resumed.runID)?.state == .cancelled)
    }

    @Test("A Keychain failure while building the transport shows the key screen and closes the run")
    func transportKeychainFailure() async throws {
        let harness = try Harness()
        harness.transportError = .keyRequired(.keychainUnreadable)
        let request = harness.request()

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == .keyRequiredKeychainUnreadable)
        #expect(harness.presented == [.keychainUnreadable])
        #expect(harness.runs.record(id: request.runID)?.state == .cancelled)
    }

    @Test("A rejected key fails the run with its listener failure and no key screen")
    func invalidKeyFails() async throws {
        let harness = try Harness()
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .failure(.invalidKey, .rejected(status: 400)))
        let request = harness.request()

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == .providerRejectedKey)
        #expect(failure.message == "Chapters & Summary failed (invalid_key).")
        let record = try #require(harness.runs.record(id: request.runID))
        #expect(record.state == .failed)
        #expect(record.listenerFailure == "invalid_key")
        #expect(harness.presented.isEmpty)
        #expect(harness.usage.isEmpty)
    }

    @Test("A trial refusal mid-run shows the key screen, refreshes the trial status and records no usage")
    func trialExhaustedMidRun() async throws {
        let harness = try Harness(route: .trial)
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .failure(.trialExhausted, .rejected(status: 403)))

        let result = await harness.producer.run(harness.request(), modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == .keyRequiredTrialExhausted)
        #expect(harness.presented == [.trialExhausted])
        #expect(harness.trialRefreshes == 1)
        #expect(harness.usage.isEmpty)
    }

    @Test("A completed trial run records no listener usage")
    func trialRunRecordsNoUsage() async throws {
        let harness = try Harness(route: .trial)
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        let request = harness.request()

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .completed(_, let completion) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        harness.producer.finish(completion)
        #expect(harness.usage.isEmpty)
        #expect(harness.runs.record(id: request.runID)?.route == .trial)
    }

    @Test("A card expiry leaves the run resumable with the same id")
    func expiryLeavesRunResumable() async throws {
        let harness = try Harness()
        harness.scheduler.launchesOnSubmit = true
        let transport = ScriptedChaptersTransport(harness: harness, answer: .holdUntilCancelled)
        harness.transport = transport
        let request = harness.request()

        let running = Task { await harness.producer.run(request, modelContext: harness.context) }
        #expect(await waitUntil { transport.isHolding && harness.scheduler.handle?.expirationHandler != nil })
        harness.scheduler.handle?.expirationHandler?()

        let result = await running.value
        guard case .expired = result else {
            Issue.record("Expected an expired run, got \(result)")
            return
        }
        #expect(harness.runs.record(id: request.runID)?.state == .expired)
        #expect(harness.runs.latestDispatched(feature: .chaptersSummary, episodeID: request.episodeID)?.id == request.runID)
        #expect(harness.usage.isEmpty)
    }

    @Test("Cancelling the caller wins over a card expiry: the run is cancelled, never resumable")
    func cancellationWinsOverExpiry() async throws {
        let harness = try Harness()
        harness.scheduler.launchesOnSubmit = true
        let transport = ScriptedChaptersTransport(harness: harness, answer: .holdUntilCancelled)
        harness.transport = transport
        let request = harness.request()

        let running = Task { await harness.producer.run(request, modelContext: harness.context) }
        #expect(await waitUntil { transport.isHolding && harness.scheduler.handle?.expirationHandler != nil })
        harness.scheduler.handle?.expirationHandler?()
        running.cancel()

        let result = await running.value
        guard case .cancelled = result else {
            Issue.record("Expected a cancelled run, got \(result)")
            return
        }
        #expect(harness.runs.record(id: request.runID)?.state == .cancelled)
        #expect(harness.runs.latestDispatched(feature: .chaptersSummary, episodeID: request.episodeID) == nil)
    }

    @Test("A resume the route no longer matches is abandoned without a send")
    func resumeUnderChangedRouteIsAbandoned() async throws {
        let harness = try Harness()
        let transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        harness.transport = transport
        let request = harness.request(isResume: true)
        try harness.runs.begin(harness.record(for: request))
        // The resolver found the run's model or policy changed and resolved
        // a new run instead.
        harness.resumingRunID = nil

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == .interrupted)
        #expect(transport.recordStateAtSend.isEmpty)
        #expect(harness.runs.record(id: request.runID)?.state == .cancelled)
        #expect(harness.presented.isEmpty)
    }

    @Test("A resume whose request changed since its run began is abandoned without a send")
    func resumeOfChangedRequestIsAbandoned() async throws {
        let harness = try Harness()
        let transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        harness.transport = transport
        let request = harness.request(isResume: true)
        try harness.runs.begin(harness.record(for: request, inputDigest: "an-earlier-request"))
        harness.resumingRunID = request.runID

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == .interrupted)
        #expect(transport.recordStateAtSend.isEmpty)
        #expect(harness.runs.record(id: request.runID)?.state == .cancelled)
        #expect(harness.presented.isEmpty)
    }

    @Test("A new run records its request's digest, which leaves out only the request id")
    func newRunRecordsInputDigest() async throws {
        let harness = try Harness()
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        let request = harness.request()

        _ = await harness.producer.run(request, modelContext: harness.context)

        #expect(harness.runs.record(id: request.runID)?.inputDigest == request.inputDigest)
        #expect(harness.request().inputDigest == request.inputDigest)
        var edited = request.analysisRequest
        edited.segments[1].text = "A different second half."
        #expect(ChaptersSummaryRunRequest.inputDigest(of: edited) != request.inputDigest)
        var retitled = request.analysisRequest
        retitled.podcastTitle = "Another Show"
        #expect(ChaptersSummaryRunRequest.inputDigest(of: retitled) != request.inputDigest)
    }

    @Test("A key removed or unreadable mid-run ends the run as needing a key, with no key screen", arguments: [
        (AnalysisKeyRequiredReason?.none, EpisodeAnalysisFailureKind.keyRequiredNoKey),
        (.some(.noKey), .keyRequiredNoKey),
        (.some(.keychainUnreadable), .keyRequiredKeychainUnreadable),
    ])
    func keyRemovedMidRunNeedsAKey(removal: AnalysisKeyRequiredReason?, expected: EpisodeAnalysisFailureKind) async throws {
        let harness = try Harness()
        // The key guard refuses the send once the key is gone.
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .failure(.keyRequired, .rejected(status: 0)))
        harness.keyRemovalReason = removal
        let request = harness.request()

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .failed(let failure) = result else {
            Issue.record("Expected a failed run, got \(result)")
            return
        }
        #expect(failure.kind == expected)
        #expect(harness.presented.isEmpty)
        #expect(harness.runs.record(id: request.runID)?.state == .failed)
        #expect(harness.runs.record(id: request.runID)?.listenerFailure == "key_required")
    }

    @Test("Removing the key in AI Services ends the run on that provider at once as needing a key, its usage counted once")
    func keyRemovedInAppEndsRunAtOnce() async throws {
        let harness = try Harness()
        let usageStore = AnalysisUsageStore()
        usageStore.load(modelContext: harness.context)
        harness.usageStore = usageStore
        // The first answer is billed but rejected, so the run retries; the
        // retry waits, as a send waits in the pacer or on the provider.
        let transport = ScriptedChaptersTransport(harness: harness, answer: .billedRetryThenHold)
        harness.transport = transport
        let (store, appModel) = try harness.storeInAppModel()
        let transcript = Harness.transcript(episodeID: "chapters-key-removed-in-app")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Producer Episode",
            podcastTitle: "Producer Show",
            modelContext: harness.context
        )
        #expect(await waitUntil { transport.isHolding })
        let runID = try #require(harness.runs.records(limit: 1).first?.id)
        // What the key sheet's Remove calls once the key is gone.
        appModel.cancelAnalysisRuns(onProvider: .google)

        // The card says what to do as soon as the run stops.
        #expect(await waitUntil { !store.hasActiveJob })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.state == .failed)
        #expect(record.failureKind == .keyRequiredNoKey)
        // The listener is where keys are added: no key screen.
        #expect(harness.presented.isEmpty)
        // The run record ends as a send that found the key gone ends it.
        let run = try #require(harness.runs.record(id: runID))
        #expect(run.state == .failed)
        #expect(run.outcomeCode == AnalysisFailureCode.providerRejected.rawValue)
        #expect(run.listenerFailure == AnalysisProviderFailure.keyRequired.rawValue)
        #expect(run.finishedAt != nil)
        #expect(run.usageRecorded == true)
        #expect(harness.runs.latestDispatched(feature: .chaptersSummary, episodeID: transcript.episodeID) == nil)
        // The billed answer counts once; nothing is sent after the removal
        // (the billed answer and the waiting retry are the run's two sends).
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
        #expect(usageStore.usage(for: .google).monthOutputTokens == 36)
        #expect(transport.recordStateAtSend.count == 2)
        harness.producer.recordUnaccountedUsage(modelContext: harness.context)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
        #expect(transport.recordStateAtSend.count == 2)
    }

    @Test("Removing another provider's key, or a key during a trial run, leaves the run going", arguments: [
        (AnalysisRoute.direct(provider: .google), AnalysisProvider.openai),
        (.trial, .google),
    ])
    func keyRemovalLeavesOtherRunsGoing(route: AnalysisRoute, removed: AnalysisProvider) async throws {
        let harness = try Harness(route: route)
        let transport = ScriptedChaptersTransport(harness: harness, answer: .holdUntilCancelled)
        harness.transport = transport
        let (store, appModel) = try harness.storeInAppModel()
        let transcript = Harness.transcript(episodeID: "chapters-key-removed-elsewhere")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Producer Episode",
            podcastTitle: "Producer Show",
            modelContext: harness.context
        )
        #expect(await waitUntil { transport.isHolding })
        let runID = try #require(harness.runs.records(limit: 1).first?.id)
        appModel.cancelAnalysisRuns(onProvider: removed)
        #expect(store.isRunning(for: transcript.episodeID))
        #expect(harness.runs.record(id: runID)?.state == .dispatched)

        // Had the removal marked it, this stop would end it as needing a
        // key; it ends as the listener's own cancellation.
        store.cancelActiveJob()
        #expect(await waitUntil { !store.hasActiveJob })
        #expect(harness.runs.record(id: runID)?.state == .cancelled)
        #expect(harness.runs.record(id: runID)?.listenerFailure == nil)
        #expect(store.record(for: transcript.episodeID)?.failureKind == ChaptersSummaryFailureMapping.interrupted.kind)
        #expect(harness.presented.isEmpty)
    }

    @Test("Cancelling a run after a billed send counts that usage once")
    func cancelAfterBilledSendCountsUsage() async throws {
        let harness = try Harness()
        let usageStore = AnalysisUsageStore()
        usageStore.load(modelContext: harness.context)
        harness.usageStore = usageStore
        let transport = ScriptedChaptersTransport(harness: harness, answer: .billedRetryThenHold)
        harness.transport = transport
        let request = harness.request()

        let running = Task { await harness.producer.run(request, modelContext: harness.context) }
        #expect(await waitUntil { transport.isHolding })
        running.cancel()
        let result = await running.value

        guard case .cancelled = result else {
            Issue.record("Expected a cancelled run, got \(result)")
            return
        }
        let record = try #require(harness.runs.record(id: request.runID))
        #expect(record.state == .cancelled)
        #expect(record.usageRecorded == true)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
        #expect(usageStore.usage(for: .google).monthOutputTokens == 36)
        // Counting again, at a load or a second close, adds nothing.
        harness.producer.recordUnaccountedUsage(modelContext: harness.context)
        harness.producer.abandon(runID: request.runID, modelContext: harness.context)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
        #expect(usageStore.usage(for: .google).monthOutputTokens == 36)
    }

    @Test("A billed run that expires and is then abandoned (its transcript deleted) counts its usage once")
    func expiredBilledRunAbandonedCountsUsage() async throws {
        let harness = try Harness()
        harness.scheduler.launchesOnSubmit = true
        let usageStore = AnalysisUsageStore()
        usageStore.load(modelContext: harness.context)
        harness.usageStore = usageStore
        let transport = ScriptedChaptersTransport(harness: harness, answer: .billedRetryThenHold)
        harness.transport = transport
        let request = harness.request()

        let running = Task { await harness.producer.run(request, modelContext: harness.context) }
        #expect(await waitUntil { transport.isHolding && harness.scheduler.handle?.expirationHandler != nil })
        harness.scheduler.handle?.expirationHandler?()
        guard case .expired = await running.value else {
            Issue.record("Expected an expired run")
            return
        }
        // An expired run stays open: nothing is counted until it ends.
        #expect(usageStore.usage(for: .google).monthInputTokens == 0)

        harness.producer.abandon(runID: request.runID, modelContext: harness.context)

        let record = try #require(harness.runs.record(id: request.runID))
        #expect(record.state == .cancelled)
        #expect(record.usageRecorded == true)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
        harness.producer.abandon(runID: request.runID, modelContext: harness.context)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
    }

    @Test("A run whose usage save failed is counted once at the next load")
    func failedUsageSaveCountedAtNextLoad() async throws {
        let harness = try Harness()
        let failing = AnalysisUsageStore(save: { _ in throw CocoaError(.fileWriteUnknown) })
        failing.load(modelContext: harness.context)
        harness.usageStore = failing
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        let request = harness.request()

        guard case .completed(_, let completion) = await harness.producer.run(request, modelContext: harness.context) else {
            Issue.record("Expected a completed run")
            return
        }
        harness.producer.finish(completion)
        #expect(harness.runs.record(id: request.runID)?.state == .finished)
        #expect(harness.runs.record(id: request.runID)?.usageRecorded != true)

        // The next launch: the usage read from what was saved, then counted.
        let relaunched = AnalysisUsageStore()
        relaunched.load(modelContext: harness.context)
        #expect(relaunched.usage(for: .google).monthInputTokens == 0)
        harness.usageStore = relaunched
        harness.producer.recordUnaccountedUsage(modelContext: harness.context)
        harness.producer.recordUnaccountedUsage(modelContext: harness.context)

        #expect(harness.runs.record(id: request.runID)?.usageRecorded == true)
        let reloaded = AnalysisUsageStore()
        reloaded.load(modelContext: harness.context)
        #expect(reloaded.usage(for: .google).monthInputTokens == 420)
        #expect(reloaded.usage(for: .google).monthOutputTokens == 36)
    }

    @Test("A resume under the same route continues the same run record")
    func resumeContinuesSameRecord() async throws {
        let harness = try Harness()
        harness.transport = ScriptedChaptersTransport(harness: harness, answer: .success)
        let request = harness.request(isResume: true)
        try harness.runs.begin(harness.record(for: request))
        harness.resumingRunID = request.runID

        let result = await harness.producer.run(request, modelContext: harness.context)

        guard case .completed(_, let completion) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        #expect(completion.runID == request.runID)
        #expect(harness.runs.records(limit: 10).count == 1)
    }

    @Test("Every failure code and listener failure maps to one kind")
    func failureMappingIsTotal() {
        for code in AnalysisFailureCode.allCases {
            _ = ChaptersSummaryFailureMapping.kind(for: code)
        }
        for failure in AnalysisProviderFailure.allCases {
            let mapped = ChaptersSummaryFailureMapping.failure(
                AnalysisFailure(feature: .chaptersSummary, code: .providerRejected, status: 502),
                listenerFailure: failure
            )
            #expect(mapped.message == "Chapters & Summary failed (\(failure.rawValue)).")
        }
        #expect(ChaptersSummaryFailureMapping.kind(for: .invalidModelOutput) == .validationExhausted)
        #expect(ChaptersSummaryFailureMapping.kind(for: .transcriptTooLong) == .validationExhausted)
        #expect(ChaptersSummaryFailureMapping.kind(for: AnalysisFailureCode.timeout) == .timedOut)
        #expect(ChaptersSummaryFailureMapping.kind(for: AnalysisProviderFailure.timeout) == .timedOut)
        #expect(ChaptersSummaryFailureMapping.kind(for: .network) == .providerUnavailable)
        #expect(ChaptersSummaryFailureMapping.kind(for: .replayMissingReply) == .generic)
        #expect(ChaptersSummaryFailureMapping.kind(for: .rateLimited) == .providerLimited)
        #expect(ChaptersSummaryFailureMapping.kind(for: .billingOrQuota) == .providerRejectedKey)
        #expect(ChaptersSummaryFailureMapping.kind(for: .trialPaused) == .keyRequiredTrialPaused)
        #expect(ChaptersSummaryFailureMapping.kind(for: .trialRunBound) == .keyRequiredTrialRunBound)
        #expect(ChaptersSummaryFailureMapping.kind(for: .trialUnavailable) == .keyRequiredProxyUnavailable)
        for reason in AnalysisKeyRequiredReason.allCases {
            #expect(ChaptersSummaryFailureMapping.failure(keyRequired: reason).kind.keyRequiredReason == reason)
        }
    }
}

// MARK: - Harness

private struct UsageCall: Equatable {
    let provider: AnalysisProvider
    let input: Int
    let output: Int
    let runID: String
}

@MainActor
private final class Harness {
    let context: ModelContext
    let runs: AnalysisRunRecordStore
    let scheduler = ProducerTestScheduler()
    let arbiter = AnalysisContinuedTaskArbiterImpl()
    let session: AnalysisExecutionSession
    let route: AnalysisRoute
    var resolution: AnalysisRouteResolution?
    var resumingRunID: String?
    var transport: (any AnalysisProviderTransport)?
    var transportError: AnalysisTransportFactoryError?
    /// The listener's usage when a test checks what was saved, not only
    /// what was asked for.
    var usageStore: AnalysisUsageStore?
    /// What the transport factory reports about a key lost mid-run.
    var keyRemovalReason: AnalysisKeyRequiredReason?
    private(set) var usage: [UsageCall] = []
    private(set) var presented: [AnalysisKeyRequiredReason] = []
    private(set) var trialRefreshes = 0
    private(set) lazy var producer: ChaptersSummaryRunProducer = makeProducer()

    init(route: AnalysisRoute = .direct(provider: .google)) throws {
        context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
        let directory = URL.temporaryDirectory.appending(path: "chapters-producer-\(UUID().uuidString)", directoryHint: .isDirectory)
        runs = AnalysisRunRecordStore(directory: directory)
        session = AnalysisExecutionSession(
            identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier,
            title: "Chapters & Summary",
            scheduler: scheduler,
            arbiter: arbiter
        )
        arbiter.chaptersSummarySession = session
        self.route = route
    }

    var policy: ChaptersSummaryAnalysisPolicy {
        AnalysisPolicySnapshot.baked.chaptersSummary(provider: .google)!
    }

    func request(isResume: Bool = false, runID: String = UUID().uuidString) -> ChaptersSummaryRunRequest {
        ChaptersSummaryRunRequest(
            runID: runID,
            isResume: isResume,
            startedByListener: !isResume,
            episodeID: "producer-episode",
            podcastID: "https://example.com/producer.xml",
            episodeTitle: "Producer Episode",
            transcriptFingerprint: "producer-fingerprint",
            analysisRequest: TranscriptAnalysisRequest(
                requestID: runID,
                episodeID: "producer-episode",
                podcastID: "https://example.com/producer.xml",
                episodeTitle: "Producer Episode",
                podcastTitle: "Producer Show",
                transcript: TranscriptAnalysisTranscript(
                    languageCode: "en",
                    audioDuration: 600,
                    fingerprint: "producer-fingerprint",
                    updatedAt: "2026-10-25T12:00:00Z",
                    segmentCount: 2
                ),
                segments: [
                    AnalysisSegment(id: 0, start: 0, end: 300, text: "Welcome to the producer test."),
                    AnalysisSegment(id: 1, start: 300, end: 600, text: "The second half of the test.")
                ]
            )
        )
    }

    /// A store inside an app model, running on this harness's producer and
    /// run records as the app wires them.
    func storeInAppModel() throws -> (EpisodeTranscriptAnalysisStore, OpenCastAppModel) {
        let directory = URL.temporaryDirectory.appending(path: "chapters-producer-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = EpisodeTranscriptAnalysisStore(
            client: ScriptedTranscriptAnalysisDrainClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: directory)
        )
        let appModel = OpenCastAppModel(transcriptAnalyses: store, analysisRuns: runs, allowsAutomaticFeedRefresh: false)
        store.producer = producer
        return (store, appModel)
    }

    static func transcript(episodeID: String) -> EpisodeTranscriptDocument {
        let segments = [
            OpenCastTranscriptSegment(id: 0, start: 0, end: 300, text: "Welcome to the producer test.", avgLogProbability: -0.1, noSpeechProbability: 0.01),
            OpenCastTranscriptSegment(id: 1, start: 300, end: 600, text: "The second half of the test.", avgLogProbability: -0.1, noSpeechProbability: 0.01)
        ]
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episodeID,
            podcastID: "https://example.com/producer.xml",
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 1_000,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: 600,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    func record(for request: ChaptersSummaryRunRequest, inputDigest: String? = nil) -> AnalysisRunRecord {
        AnalysisRunRecord(
            id: request.runID,
            feature: .chaptersSummary,
            episodeID: request.episodeID,
            podcastID: request.podcastID,
            transcriptFingerprint: request.transcriptFingerprint,
            inputDigest: inputDigest ?? request.inputDigest,
            resolution: currentResolution(resuming: nil),
            policy: .chaptersSummary(policy)
        )
    }

    private func currentResolution(resuming runID: String?) -> AnalysisRouteResolution {
        if let resolution {
            return resolution
        }
        return AnalysisRouteResolution(
            feature: .chaptersSummary,
            route: route,
            policy: .chaptersSummary(policy),
            key: route == .trial ? nil : AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText),
            resumingRunID: runID,
            trialExchange: nil
        )
    }

    private func makeProducer() -> ChaptersSummaryRunProducer {
        ChaptersSummaryRunProducer(dependencies: ChaptersSummaryRunProducer.Dependencies(
            resolve: { [unowned self] resuming in
                currentResolution(resuming: resuming == nil ? nil : resumingRunID)
            },
            runs: runs,
            makeTransport: { [unowned self] _, _, observer throws(AnalysisTransportFactoryError) in
                if let transportError {
                    throw transportError
                }
                guard let transport = transport as? ScriptedChaptersTransport else {
                    throw .keyRequired(.noKey)
                }
                return transport.observing(observer)
            },
            session: session,
            recordUsage: { [unowned self] provider, input, output, runID, modelContext in
                usage.append(UsageCall(provider: provider, input: input, output: output, runID: runID))
                return usageStore?.record(
                    provider: provider,
                    feature: .chaptersSummary,
                    inputTokens: input,
                    outputTokens: output,
                    at: .now,
                    runID: runID,
                    modelContext: modelContext
                ) ?? true
            },
            presentKeyRequired: { [unowned self] reason in
                presented.append(reason)
            },
            refreshTrialStatus: { [unowned self] in
                trialRefreshes += 1
            },
            keyRemoval: { [unowned self] _ in
                keyRemovalReason
            },
            clock: AnalysisFrozenClock()
        ))
    }
}

/// Answers the run's first Chapters attempt: a valid two-chapter answer, a
/// scripted provider failure, or a hold that ends only when the run is
/// cancelled. Every answer is reported to the run's observer as a real
/// transport does, and each send notes the run record's state at that
/// moment.
private final class ScriptedChaptersTransport: AnalysisProviderTransport, @unchecked Sendable {
    enum Answer {
        case success
        case failure(AnalysisProviderFailure, AnalysisTransportError)
        case holdUntilCancelled
        /// A billed answer the pipeline rejects, so it retries; the retry
        /// holds until the run is cancelled.
        case billedRetryThenHold
    }

    private let runs: AnalysisRunRecordStore
    private let answer: Answer
    private let state = Mutex<(observer: (any AnalysisProviderSendObserver)?, states: [AnalysisRunRecord.State], holding: Bool)>((nil, [], false))

    @MainActor
    init(harness: Harness, answer: Answer) {
        runs = harness.runs
        self.answer = answer
    }

    var recordStateAtSend: [AnalysisRunRecord.State] {
        state.withLock { $0.states }
    }

    var isHolding: Bool {
        state.withLock { $0.holding }
    }

    func observing(_ observer: any AnalysisProviderSendObserver) -> ScriptedChaptersTransport {
        state.withLock { $0.observer = observer }
        return self
    }

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        let runID = runIDFromRecords()
        let observer = state.withLock { current -> (any AnalysisProviderSendObserver)? in
            if let record = runs.record(id: runID) {
                current.states.append(record.state)
            }
            return current.observer
        }
        func record(status: Int?, failure: AnalysisProviderFailure?, usage: AnalysisBilledUsage?, cancelled: Bool = false) {
            observer?.record(AnalysisProviderSendRecord(
                provider: request.model.provider,
                modelID: request.model.modelID,
                feature: request.feature,
                purpose: request.purpose,
                sendIndex: request.sendIndex,
                status: status,
                finishReason: status == 200 ? .stop : nil,
                failure: failure,
                cancelled: cancelled,
                usage: usage,
                pacedSeconds: 0,
                exchangeSeconds: 0.5
            ))
        }
        switch answer {
        case .success:
            record(status: 200, failure: nil, usage: AnalysisBilledUsage(input: 420, cached: 0, write: 0, output: 36, reasoning: 0))
            return .geminiBody(Self.validBody)
        case .failure(let failure, let error):
            record(status: 400, failure: failure, usage: nil)
            throw error
        case .billedRetryThenHold where Self.isFirstAttempt(request):
            record(status: 200, failure: nil, usage: AnalysisBilledUsage(input: 420, cached: 0, write: 0, output: 36, reasoning: 0))
            return .geminiBody(Self.rejectedBody)
        case .holdUntilCancelled, .billedRetryThenHold:
            state.withLock { $0.holding = true }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            record(status: nil, failure: nil, usage: nil, cancelled: true)
            throw .network
        }
    }

    /// The dispatched record the run wrote before this send.
    private func runIDFromRecords() -> String {
        runs.records(limit: 1).first?.id ?? ""
    }

    private static func isFirstAttempt(_ request: AnalysisProviderRequest) -> Bool {
        if case .chapters(attempt: 0) = request.purpose {
            return true
        }
        return false
    }

    /// A complete reply whose answer is not the contract's JSON.
    static let rejectedBody: String = {
        let body: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": "not the requested JSON"]], "role": "model"],
                "finishReason": "STOP",
            ]],
            "usageMetadata": ["promptTokenCount": 420, "candidatesTokenCount": 36, "totalTokenCount": 456],
        ]
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }()

    static let validBody: String = {
        let answer = #"{"chapters":[{"title":"Part One","start_segment_id":0,"end_segment_id":0,"confidence":0.9},{"title":"Part Two","start_segment_id":1,"end_segment_id":1,"confidence":0.9}],"summary":{"summary":"A test summary.","one_line_description":"A test episode","claims":[{"text":"It opens.","evidence_segment_id":0}]}}"#
        let body: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": answer]], "role": "model"],
                "finishReason": "STOP",
            ]],
            "usageMetadata": ["promptTokenCount": 420, "candidatesTokenCount": 36, "totalTokenCount": 456],
        ]
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }()
}

@MainActor
private final class ProducerTestHandle: AnalysisContinuedTaskHandle {
    let progress = Progress(totalUnitCount: 0)
    private(set) var expirationHandler: (@Sendable () -> Void)?

    func updateTitle(_ title: String, subtitle: String) {}
    func setTaskCompleted(success: Bool) {}
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        expirationHandler = handler
    }
}

@MainActor
private final class ProducerTestScheduler: AnalysisContinuedTaskScheduling {
    var launchesOnSubmit = false
    private(set) var submitted: [String] = []
    private(set) var handle: ProducerTestHandle?
    private var launchHandler: (@MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void)?

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> Bool {
        launchHandler = onLaunch
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {
        submitted.append(identifier)
        guard launchesOnSubmit else {
            throw CancellationError()
        }
        let handle = ProducerTestHandle()
        self.handle = handle
        let launchHandler = launchHandler
        Task { @MainActor in
            launchHandler?(handle)
        }
    }

    func cancel(identifier: String) {}
}
