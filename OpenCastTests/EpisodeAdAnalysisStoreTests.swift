import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad analysis store")
struct EpisodeAdAnalysisStoreTests {
    @Test("A direct run installs the break a validating reply names and counts the run once")
    func directRunInstallsValidatedBreak() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        let environment = ScriptedAdAnalysisRunEnvironment()
        let client = UnpolledAdAnalysisClient()
        let store = makeStore(fileStore: fileStore, environment: environment, client: client)
        let transcript = makeTranscriptDocument(episodeID: "ad-create")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let model = try #require(environment.snapshot.adDetection(provider: .google)).model
        #expect(record.spanCount == 1)
        #expect(record.transcriptState == .completed)
        #expect(record.model == model.modelID)
        #expect(EpisodeAdAnalysisContract.supports(policy: record.policy))
        #expect(document.spans.first?.kind == .hostReadAd)
        #expect(document.spans.first?.label == "Sponsor read")
        #expect(document.spans.first?.startSegmentID == 1)
        #expect(document.transcriptSegmentCount == transcript.segments.count)
        #expect(document.transcriptState == .completed)
        #expect(document.policyRevision == environment.adDetectionPolicyRevision)
        #expect(store.isCurrentAnalysisDocument(document, for: transcript))

        // The pipeline sends the normalized segments and nothing about the
        // source file.
        #expect(environment.sends.firstSegments.map(\.text) == transcript.segments.map(\.text))
        let payload = try #require(environment.sends.all.first?.payloadText)
        #expect(!payload.contains(transcript.sourceAudioURL))
        #expect(!payload.contains(transcript.sourceFileSHA256))
        #expect(!payload.contains(String(transcript.sourceFileByteCount)))

        let run = try #require(environment.latestRun)
        #expect(run.state == .finished)
        #expect(run.outcomeCode == "completed")
        #expect(run.route == .direct)
        #expect(run.provider == .google)
        #expect(run.modelID == model.modelID)
        #expect(run.episodeID == transcript.episodeID)
        #expect(run.transcriptFingerprint == record.transcriptFingerprint)
        #expect(run.policyRevision == environment.adDetectionPolicyRevision)
        #expect(run.windows == ["0": .init(verdict: .accepted, sends: 1)])
        let inputDigest = try #require(run.inputDigest)
        #expect(inputDigest.count == 64)
        #expect(inputDigest.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(environment.usage == [.init(provider: .google, inputTokens: 420, outputTokens: 36, runID: run.id)])
        // Usage is counted while the run is still open, before it ends.
        #expect(environment.usageRunStates == [.dispatched])
        #expect(environment.transportRunIDs == [run.id])
        #expect(environment.resolvedRunIDs == [nil])
        #expect(client.pollCount == 0)
        #expect(store.analysisProgress(for: transcript.episodeID) == nil)
    }

    @Test("A trial run completes on the trial's model without counting the listener's usage")
    func trialRunCompletesWithoutUsage() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.route = .trial
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-trial")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let run = try #require(environment.latestRun)
        #expect(run.route == .trial)
        #expect(run.provider == .google)
        #expect(run.modelID == environment.snapshot.bundle.trial.modelID)
        #expect(run.state == .finished)
        #expect(environment.usage.isEmpty)
        #expect(store.record(for: transcript.episodeID)?.spanCount == 1)
    }

    @Test("A route that needs the listener's key fails the run, and only a start that asks opens the key screen")
    func keyRequiredRouteFailsAndPresentsOnlyWhenAsked() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.route = .keyRequired(.trialExhausted)
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let automatic = makeTranscriptDocument(episodeID: "ad-key-required-automatic")
        let listener = makeTranscriptDocument(episodeID: "ad-key-required-listener")

        store.startAnalysis(transcript: automatic, presentsKeyScreen: false, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: automatic.episodeID)?.state == .failed
        })
        #expect(store.record(for: automatic.episodeID)?.failureKind == .keyRequiredTrialExhausted)
        #expect(environment.presentedReasons.isEmpty)

        store.startAnalysis(transcript: listener, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: listener.episodeID)?.state == .failed
        })
        #expect(store.record(for: listener.episodeID)?.failureKind == .keyRequiredTrialExhausted)
        #expect(environment.presentedReasons == [.trialExhausted])
        #expect(store.lastErrorMessage(for: listener.episodeID) == EpisodeAdAnalysisError.keyRequired(.trialExhausted).localizedDescription)
        #expect(environment.sends.count == 0)
        #expect(environment.transportRunIDs.isEmpty)
        #expect(environment.runs.records(limit: 10).isEmpty)
    }

    @Test(
        "A provider's refusal fails the run with the listener's kind and no key screen",
        arguments: [
            ProviderRefusal(
                answer: .failure(.rejected(status: 400), status: 400, listener: .invalidKey),
                kind: .providerRejectedKey,
                listener: .invalidKey,
                code: "gemini_http_error"
            ),
            ProviderRefusal(
                answer: .failure(.quotaExhausted, status: 429, listener: .billingOrQuota),
                kind: .providerRejectedKey,
                listener: .billingOrQuota,
                code: "gemini_quota_exhausted"
            ),
            ProviderRefusal(
                answer: .failure(.quotaExhausted, status: 429, listener: .dailyLimit),
                kind: .providerLimited,
                listener: .dailyLimit,
                code: "gemini_quota_exhausted"
            ),
            ProviderRefusal(
                answer: .failure(.retryable(status: 503, retryAfterSeconds: 0), status: 503, listener: .overloaded),
                kind: .providerLimited,
                listener: .overloaded,
                code: "gemini_retry_exhausted"
            ),
            ProviderRefusal(
                answer: .failure(.network, status: nil, listener: .unreachable),
                kind: .providerUnavailable,
                listener: .unreachable,
                code: "worker_fetch_error"
            ),
            ProviderRefusal(
                answer: .failure(.timeout, status: nil, listener: .timeout),
                kind: .timedOut,
                listener: .timeout,
                code: "gemini_timeout"
            ),
            ProviderRefusal(
                answer: .failure(.rejected(status: 404), status: 404, listener: .modelUnavailable),
                kind: .providerUnavailable,
                listener: .modelUnavailable,
                code: "gemini_http_error"
            ),
            ProviderRefusal(
                answer: .failure(.retryable(status: 429, retryAfterSeconds: 0), status: 429, listener: .rateLimited),
                kind: .providerLimited,
                listener: .rateLimited,
                code: "gemini_retry_exhausted"
            ),
            ProviderRefusal(
                answer: .failure(.oversizedBody, status: 200, listener: .malformedAnswer),
                kind: .generic,
                listener: .malformedAnswer,
                code: "gemini_response_oversized"
            ),
            ProviderRefusal(
                answer: .failure(.invalidEncoding, status: 200, listener: .malformedAnswer),
                kind: .generic,
                listener: .malformedAnswer,
                code: "gemini_response_encoding"
            ),
            // A retry hint longer than the run's longest pause cannot fit
            // its budget: the deadline is exhausted.
            ProviderRefusal(
                answer: .failure(.retryable(status: 503, retryAfterSeconds: 30), status: 503, listener: .overloaded),
                kind: .timedOut,
                listener: .timeout,
                code: "analysis_deadline_exhausted"
            ),
        ]
    )
    func providerRefusalThreadsListenerKind(_ refusal: ProviderRefusal) async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = refusal.answer
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-refusal-\(refusal.code)-\(refusal.listener.rawValue)")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == refusal.kind)
        #expect(record.errorMessage == "Promo/ad analysis failed (\(refusal.code), \(refusal.listener.rawValue)).")
        #expect(store.document(for: transcript.episodeID) == nil)
        let run = try #require(environment.latestRun)
        #expect(run.state == .failed)
        #expect(run.outcomeCode == refusal.code)
        #expect(run.listenerFailure == refusal.listener.rawValue)
        #expect(run.windows["0"]?.verdict == .failed)
        #expect(environment.presentedReasons.isEmpty)
        #expect(environment.trialRefreshCount == 0)
        // No tokens were spent, so the listener's usage is untouched.
        #expect(environment.usage.isEmpty)
    }

    @Test("A trial refusal reads the trial status again and opens the key screen with its reason")
    func trialRefusalRefreshesStatusAndPresentsKeyScreen() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.route = .trial
        environment.answer = .failure(.rejected(status: 403), status: 403, listener: .trialExhausted)
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let exhausted = makeTranscriptDocument(episodeID: "ad-trial-exhausted")
        let paused = makeTranscriptDocument(episodeID: "ad-trial-paused")

        store.startAnalysis(transcript: exhausted, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: exhausted.episodeID)?.state == .failed
        })
        environment.answer = .failure(.rejected(status: 503), status: 503, listener: .trialPaused)
        store.startAnalysis(transcript: paused, presentsKeyScreen: false, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: paused.episodeID)?.state == .failed
        })

        #expect(store.record(for: exhausted.episodeID)?.failureKind == .keyRequiredTrialExhausted)
        #expect(store.record(for: paused.episodeID)?.failureKind == .keyRequiredTrialPaused)
        #expect(environment.trialRefreshCount == 2)
        #expect(environment.presentedReasons == [.trialExhausted])
        #expect(environment.usage.isEmpty)
    }

    @Test(
        "A trial refusal that needs the listener's key fails with its reason, and only a listener's start opens the key screen",
        arguments: [
            TrialRefusal(
                answer: .failure(.rejected(status: 403), status: 403, listener: .trialRunBound),
                kind: .keyRequiredTrialRunBound,
                reason: .trialRunBound
            ),
            TrialRefusal(
                answer: .failure(.rejected(status: 503), status: 503, listener: .trialUnavailable),
                kind: .keyRequiredProxyUnavailable,
                reason: .proxyUnavailable
            ),
        ]
    )
    func trialRefusalNeedsListenerKey(_ refusal: TrialRefusal) async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.route = .trial
        environment.answer = refusal.answer
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let automatic = makeTranscriptDocument(episodeID: "ad-trial-automatic-\(refusal.reason.rawValue)")
        let listener = makeTranscriptDocument(episodeID: "ad-trial-listener-\(refusal.reason.rawValue)")

        store.startAnalysis(transcript: automatic, retryFailed: false, presentsKeyScreen: false, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: automatic.episodeID)?.state == .failed
        })
        #expect(environment.presentedReasons.isEmpty)

        store.startAnalysis(transcript: listener, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: listener.episodeID)?.state == .failed
        })

        #expect(store.record(for: automatic.episodeID)?.failureKind == refusal.kind)
        #expect(store.record(for: listener.episodeID)?.failureKind == refusal.kind)
        #expect(environment.presentedReasons == [refusal.reason])
        #expect(environment.trialRefreshCount == 0)
        #expect(environment.latestRun?.listenerFailure == refusal.answerListener.rawValue)
        #expect(environment.usage.isEmpty)
    }

    @Test("A document that fails to install leaves its run open, and the next start resumes it without paying again")
    func failedInstallLeavesRunOpenForNextStart() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(fileStore: fileStore, environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "ad-install-failure")
        // A directory where the document goes makes its write fail.
        let blocker = fileStore.fileURL(relativePath: fileStore.relativePath(
            episodeID: transcript.episodeID,
            transcriptFingerprint: fileStore.transcriptFingerprint(for: transcript)
        ))
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: blocker.appending(path: "occupied"))

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(store.record(for: transcript.episodeID)?.failureKind == .generic)
        let open = try #require(environment.latestRun)
        #expect(open.state == .dispatched)
        #expect(open.finishedAt == nil)
        #expect(environment.runs.replies(runID: open.id).count == 1)
        #expect(environment.usage.isEmpty)

        try FileManager.default.removeItem(at: blocker)
        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(environment.resolvedRunIDs == [nil, open.id])
        #expect(environment.transportRunIDs == [open.id, open.id])
        #expect(environment.sends.count == 1)
        #expect(environment.runs.record(id: open.id)?.state == .finished)
        #expect(environment.usage == [.init(provider: .google, inputTokens: 420, outputTokens: 36, runID: open.id)])
        #expect(store.document(for: transcript.episodeID)?.spans.count == 1)
    }

    @Test("The run record is written before the first send and ends only after the document is in place")
    func runRecordBracketsTheDocument() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.gate = gate
        environment.perCallTimeoutSeconds = 45
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-run-record-order")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil { environment.sends.count == 1 })
        let dispatched = try #require(environment.latestRun)
        #expect(dispatched.state == .dispatched)
        #expect(dispatched.finishedAt == nil)
        #expect(store.record(for: transcript.episodeID)?.state == .running)
        #expect(store.document(for: transcript.episodeID) == nil)
        let progress = try #require(store.analysisProgress(for: transcript.episodeID))
        #expect(progress.completed == 0)
        #expect(progress.total == 1)
        // Each step's creep paces over the run's own model.
        #expect(progress.stepBudgetSeconds == AdAnalysisRunProgress.stepBudgetSeconds(perCallTimeoutSeconds: 45))

        await gate.release()

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let finished = try #require(environment.runs.record(id: dispatched.id))
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(finished.state == .finished)
        #expect(finished.windows == ["0": .init(verdict: .accepted, sends: 1)])
        let finishedAt = try #require(finished.finishedAt)
        #expect(finishedAt >= record.updatedAt)
        #expect(environment.runs.replies(runID: dispatched.id).isEmpty)
    }

    @Test("A listener's cancel ends the run record cancelled, and the next launch does not resume it")
    func listenerCancelEndsRunRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .hold
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "ad-listener-cancel")
        _ = try writeTranscript(transcript, fileStore: transcriptFileStore, modelContext: context)

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil { environment.sends.count == 1 })
        store.cancelActiveRun(reason: .listener)

        #expect(await waitUntil { !store.hasActiveJob })
        let run = try #require(environment.latestRun)
        #expect(run.state == .cancelled)
        #expect(run.outcomeCode == "cancelled")
        #expect(store.record(for: transcript.episodeID)?.state == .running)

        let relaunched = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        relaunched.load(modelContext: context)

        let record = try #require(relaunched.record(for: transcript.episodeID))
        #expect(record.state == .failed)
        #expect(record.failureKind == .interrupted)
        #expect(!relaunched.hasActiveJob)
        #expect(environment.resolvedRunIDs == [nil])
        #expect(environment.sends.count == 1)
    }

    @Test("A run whose card expired resumes at the next launch under its id, sending only the windows it had not answered")
    func expiredRunResumesAtLaunchFromKeptReplies() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answerForRequest = { request in
            request.purpose == .adWindow(index: 1) ? .hold : .sponsorRead
        }
        let client = UnpolledAdAnalysisClient()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            environment: environment,
            client: client
        )
        let transcript = makeLongTranscriptDocument(episodeID: "ad-expired-resume", segmentCount: 900)
        _ = try writeTranscript(transcript, fileStore: transcriptFileStore, modelContext: context)

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            environment.sends.count(of: .adWindow(index: 1)) == 1
                && store.analysisProgress(for: transcript.episodeID)?.completed == 1
        })
        #expect(store.analysisProgress(for: transcript.episodeID)?.total == 2)
        store.cancelActiveRun(reason: .expiration)

        #expect(await waitUntil { !store.hasActiveJob })
        let expired = try #require(environment.latestRun)
        #expect(expired.state == .expired)
        #expect(expired.windows["0"]?.verdict == .answered)
        #expect(environment.runs.replies(runID: expired.id).count == 1)
        #expect(store.record(for: transcript.episodeID)?.state == .running)

        environment.answerForRequest = nil
        let relaunched = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            environment: environment,
            client: client
        )
        relaunched.load(modelContext: context)

        #expect(await waitUntil {
            !relaunched.hasActiveJob && relaunched.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(environment.resolvedRunIDs == [nil, expired.id])
        #expect(environment.transportRunIDs == [expired.id, expired.id])
        #expect(environment.sends.count(of: .adWindow(index: 0)) == 1)
        #expect(environment.sends.count(of: .adWindow(index: 1)) == 2)
        let finished = try #require(environment.runs.record(id: expired.id))
        #expect(finished.state == .finished)
        #expect(finished.windows.values.allSatisfy { $0.verdict == .accepted })
        #expect(environment.runs.records(limit: 10).count == 1)
        #expect(environment.usage == [.init(provider: .google, inputTokens: 840, outputTokens: 72, runID: expired.id)])
        #expect(relaunched.record(for: transcript.episodeID)?.spanCount == 1)
        #expect(client.pollCount == 0)
    }

    @Test("A new start resumes the episode's expired run instead of dispatching another")
    func newStartResumesExpiredRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.route = .trial
        environment.answer = .hold
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-restart-expired")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil { environment.sends.count == 1 })
        store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !store.hasActiveJob })
        let expired = try #require(environment.latestRun)
        #expect(expired.state == .expired)

        environment.answer = .sponsorRead
        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(environment.resolvedRunIDs == [nil, expired.id])
        #expect(environment.transportRunIDs == [expired.id, expired.id])
        #expect(environment.runs.records(limit: 10).map(\.id) == [expired.id])
        #expect(environment.runs.record(id: expired.id)?.state == .finished)
    }

    @Test("At most one device run resumes at launch; the other running records fail as interrupted")
    func atMostOneDeviceRunResumesAtLaunch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .hold
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        var openRuns: [String: String] = [:]
        for episodeID in ["ad-launch-first", "ad-launch-second"] {
            let transcript = makeTranscriptDocument(episodeID: episodeID)
            _ = try writeTranscript(transcript, fileStore: transcriptFileStore, modelContext: context)
            openRuns[episodeID] = try await expireRun(of: transcript, store: store, environment: environment, context: context)
        }

        environment.answer = .sponsorRead
        let relaunched = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        relaunched.load(modelContext: context)

        #expect(await waitUntil {
            !relaunched.hasActiveJob
                && relaunched.records.allSatisfy { $0.state == .completed || $0.state == .failed }
        })
        let completed = relaunched.records.filter { $0.state == .completed }
        let failed = relaunched.records.filter { $0.state == .failed }
        #expect(completed.count == 1)
        #expect(failed.count == 1)
        #expect(failed.first?.failureKind == .interrupted)
        let resumedEpisodeID = try #require(completed.first?.episodeID)
        let resumedRunID = try #require(openRuns[resumedEpisodeID])
        #expect(environment.resolvedRunIDs == [nil, nil, resumedRunID])
        #expect(environment.transportRunIDs.last == resumedRunID)
        #expect(environment.runs.record(id: resumedRunID)?.state == .finished)
    }

    @Test("A launch never starts a new run when the open run's route no longer applies")
    func launchNeverStartsNewRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .hold
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "ad-launch-no-new-run")
        _ = try writeTranscript(transcript, fileStore: EpisodeTranscriptFileStore(baseDirectory: directory), modelContext: context)
        let runID = try await expireRun(of: transcript, store: store, environment: environment, context: context)

        environment.keepsResumedRoute = false
        environment.answer = .sponsorRead
        let relaunched = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        relaunched.load(modelContext: context)

        #expect(await waitUntil {
            !relaunched.hasActiveJob && relaunched.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(relaunched.record(for: transcript.episodeID)?.failureKind == .interrupted)
        #expect(environment.resolvedRunIDs == [nil, runID])
        #expect(environment.transportRunIDs == [runID])
        #expect(environment.sends.count == 1)
        #expect(environment.presentedReasons.isEmpty)
    }

    @Test("A declared runtime that changed after the kill keeps the next launch from reusing the kept replies")
    func changedDeclaredRuntimeBlocksResumeAtLaunch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let environment = ScriptedAdAnalysisRunEnvironment()
        let transcript = makeLongTranscriptDocument(episodeID: "ad-declared-runtime-launch", segmentCount: 900)
        _ = try writeTranscript(transcript, fileStore: EpisodeTranscriptFileStore(baseDirectory: directory), modelContext: context)
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        let expired = try await expireAfterFirstWindow(of: transcript, store: store, environment: environment, context: context)
        #expect(environment.runs.replies(runID: expired).count == 1)

        try insertDeclaredRuntime(1_700, for: transcript, context: context)
        let relaunched = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        relaunched.load(modelContext: context)

        #expect(await waitUntil {
            !relaunched.hasActiveJob && relaunched.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(relaunched.record(for: transcript.episodeID)?.failureKind == .interrupted)
        #expect(environment.runs.record(id: expired)?.state == .cancelled)
        #expect(environment.runs.replies(runID: expired).isEmpty)
        // No route was resolved and nothing was sent at the launch.
        #expect(environment.resolvedRunIDs == [nil])
        #expect(environment.sends.count(of: .adWindow(index: 0)) == 1)
        // The closed run's spent tokens still count, once, before it closes.
        #expect(environment.usage == [.init(provider: .google, inputTokens: 420, outputTokens: 36, runID: expired)])
        #expect(environment.usageRunStates == [.expired])
    }

    @Test("A declared runtime that changed after the card expired makes the next start dispatch a new run")
    func changedDeclaredRuntimeStartsNewRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        let transcript = makeLongTranscriptDocument(episodeID: "ad-declared-runtime-start", segmentCount: 900)
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let expired = try await expireAfterFirstWindow(of: transcript, store: store, environment: environment, context: context)

        try insertDeclaredRuntime(1_700, for: transcript, context: context)
        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(environment.resolvedRunIDs == [nil, nil])
        #expect(environment.transportRunIDs.count == 2)
        let fresh = try #require(environment.transportRunIDs.last)
        #expect(fresh != expired)
        #expect(environment.runs.record(id: expired)?.state == .cancelled)
        #expect(environment.runs.record(id: fresh)?.state == .finished)
        #expect(environment.runs.record(id: fresh)?.inputDigest != environment.runs.record(id: expired)?.inputDigest)
        #expect(environment.sends.count(of: .adWindow(index: 0)) == 2)
    }

    @Test("A run killed after its document was installed finishes at the next launch, its usage counted once")
    func installedRunFinishesAtLaunch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let runsDirectory = try makeTemporaryDirectory()
        let environment = ScriptedAdAnalysisRunEnvironment(directory: runsDirectory)
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "ad-installed-run")
        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let runID = try #require(environment.latestRun?.id)
        let request = try #require(environment.sends.all.first)
        // The process died between the install and the run record's end.
        environment.runs.update(runID: runID) { record in
            record.state = .dispatched
            record.outcomeCode = nil
            record.finishedAt = nil
            record.windows["0"]?.verdict = .answered
        }
        environment.runs.saveReply(AnalysisRunStoredReply(.geminiBody("{}")), for: AnalysisRunReplyKey(request), runID: runID)

        let relaunchedEnvironment = ScriptedAdAnalysisRunEnvironment(directory: runsDirectory)
        let relaunched = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: relaunchedEnvironment)
        relaunched.load(modelContext: context)

        let finished = try #require(relaunchedEnvironment.runs.record(id: runID))
        #expect(finished.state == .finished)
        #expect(finished.outcomeCode == "completed")
        #expect(finished.windows == ["0": .init(verdict: .accepted, sends: 1)])
        #expect(relaunchedEnvironment.runs.replies(runID: runID).isEmpty)
        #expect(relaunchedEnvironment.usage == [.init(provider: .google, inputTokens: 420, outputTokens: 36, runID: runID)])
        #expect(relaunchedEnvironment.usageRunStates == [.dispatched])
        #expect(relaunched.record(for: transcript.episodeID)?.state == .completed)
        #expect(!relaunched.hasActiveJob)
        #expect(relaunchedEnvironment.resolvedRunIDs.isEmpty)
        #expect(relaunchedEnvironment.sends.count == 0)

        // An ended run is not finished or counted again.
        let againEnvironment = ScriptedAdAnalysisRunEnvironment(directory: runsDirectory)
        makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: againEnvironment)
            .load(modelContext: context)
        #expect(againEnvironment.usage.isEmpty)
    }

    @Test("A run counted part-way and killed before it ended counts its full totals once when it resumes")
    func partlyCountedRunCountsFullTotalsOnResume() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let environment = ScriptedAdAnalysisRunEnvironment()
        let usageStore = AnalysisUsageStore()
        environment.usageStore = usageStore
        let transcript = makeLongTranscriptDocument(episodeID: "ad-partly-counted", segmentCount: 900)
        _ = try writeTranscript(transcript, fileStore: EpisodeTranscriptFileStore(baseDirectory: directory), modelContext: context)
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        let runID = try await expireAfterFirstWindow(of: transcript, store: store, environment: environment, context: context)
        // A cancel counted the totals so far under the run id, and the
        // process stopped before the run ended: the run is still open.
        let partial = try #require(environment.runs.record(id: runID))
        #expect(usageStore.record(
            provider: .google,
            feature: .adDetection,
            inputTokens: Int(partial.inputTokens),
            outputTokens: Int(partial.outputTokens),
            at: .now,
            runID: runID,
            modelContext: context
        ))
        environment.runs.markUsageRecorded(runID: runID)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)

        let relaunched = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        relaunched.load(modelContext: context)

        #expect(await waitUntil {
            !relaunched.hasActiveJob && relaunched.record(for: transcript.episodeID)?.state == .completed
        })
        let finished = try #require(environment.runs.record(id: runID))
        #expect(finished.state == .finished)
        #expect(finished.inputTokens == 840)
        #expect(finished.outputTokens == 72)
        #expect(finished.usageRecorded == true)
        let usage = usageStore.usage(for: .google)
        #expect(usage.monthInputTokens == 840)
        #expect(usage.monthOutputTokens == 72)
        #expect(usage.lastRun?.inputTokens == 840)
        #expect(usage.lastRun?.outputTokens == 72)
    }

    @Test("A usage count whose save failed is counted at the next launch, once")
    func failedUsageSaveCountsAtNextLaunch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let saves = UsageSaveSwitch()
        let usageStore = AnalysisUsageStore(save: { context in
            if saves.fails { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.usageStore = usageStore
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "ad-usage-save-failure")

        await startAndWait(store: store, transcript: transcript, modelContext: context)

        let run = try #require(environment.latestRun)
        #expect(run.state == .finished)
        #expect(run.usageRecorded != true)
        #expect(usageStore.usage(for: .google).monthInputTokens == 0)
        #expect(environment.runs.unaccountedDirectRuns(feature: .adDetection).map(\.id) == [run.id])

        saves.fails = false
        makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
            .load(modelContext: context)

        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
        #expect(usageStore.usage(for: .google).monthOutputTokens == 36)
        #expect(environment.runs.record(id: run.id)?.usageRecorded == true)
        #expect(environment.runs.unaccountedDirectRuns(feature: .adDetection).isEmpty)

        makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory), environment: environment)
            .load(modelContext: context)
        #expect(usageStore.usage(for: .google).monthInputTokens == 420)
    }

    @Test("A key removed mid-run fails the run as needing a key, and only a listener's start opens the key screen")
    func keyRemovedMidRunNeedsKey() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.keyStorage = keys
        // The window's answer does not validate, so the run needs a
        // corrective request; the key goes before it is sent.
        environment.answer = .unverifiableBreak
        environment.onSend = { request in
            if request.purpose == .adWindow(index: 0) {
                try? keys.remove(provider: .google, includingSyncedCopy: true)
            }
        }
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let listener = makeTranscriptDocument(episodeID: "ad-key-removed-listener")
        let automatic = makeTranscriptDocument(episodeID: "ad-key-removed-automatic")

        store.startAnalysis(transcript: listener, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: listener.episodeID)?.state == .failed
        })
        let run = try #require(environment.latestRun)
        #expect(store.record(for: listener.episodeID)?.failureKind == .keyRequiredNoKey)
        #expect(environment.presentedReasons == [.noKey])
        #expect(environment.keyRemoval(runID: run.id) == .noKey)
        #expect(run.state == .failed)
        #expect(run.outcomeCode == AnalysisFailureCode.providerRejected.rawValue)
        #expect(run.listenerFailure == AnalysisProviderFailure.keyRequired.rawValue)
        #expect(environment.sends.count(of: .adWindow(index: 0)) == 1)
        #expect(environment.sends.count(of: .adRepair(index: 0)) == 0)
        // What was sent before the key went still counts, before the run ends.
        #expect(environment.usage == [.init(provider: .google, inputTokens: 420, outputTokens: 36, runID: run.id)])
        #expect(environment.usageRunStates == [.dispatched])
        // A run that needs a key pauses nothing for the transcript.
        #expect(try await store.automaticReplayError(for: listener) == nil)

        try keys.save(ScriptedAdAnalysisRunEnvironment.key, provider: .google, syncs: false)
        store.startAnalysis(transcript: automatic, retryFailed: false, presentsKeyScreen: false, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: automatic.episodeID)?.state == .failed
        })
        #expect(store.record(for: automatic.episodeID)?.failureKind == .keyRequiredNoKey)
        #expect(environment.presentedReasons == [.noKey])
    }

    @Test("Removing the key in AI Services ends the run at once as a removal from another device does, without the key screen")
    func keyRemovedInAppEndsRunAsNeedingKey() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (ScriptedAdAnalysisRunEnvironment.key, syncs: false)])
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.keyStorage = keys
        // The window's answer does not validate and its corrective request
        // waits, so the run has tokens to count when the key goes.
        environment.answerForRequest = { request in
            request.purpose == .adRepair(index: 0) ? .hold : .unverifiableBreak
        }
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let appModel = OpenCastAppModel(adAnalyses: store, allowsAutomaticFeedRefresh: false)
        let transcript = makeTranscriptDocument(episodeID: "ad-key-removed-in-app")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil { environment.sends.count(of: .adRepair(index: 0)) == 1 })
        try keys.remove(provider: .google, includingSyncedCopy: true)
        appModel.cancelAnalysisRuns(onProvider: .google)

        // The card says what to do as soon as the run stops.
        #expect(await waitUntil { !store.hasActiveJob })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.state == .failed)
        #expect(record.failureKind == .keyRequiredNoKey)
        #expect(EpisodePipelineState.analysisFailedMessage(for: record.failureKind) == "Add a key in Settings › AI Services to detect ads.")
        #expect(store.endedForKeyRemoval(episodeID: transcript.episodeID))
        // The listener is where keys are added: no key screen.
        #expect(environment.presentedReasons.isEmpty)
        // The run record ends as a send that found the key gone ends it.
        let run = try #require(environment.latestRun)
        #expect(run.state == .failed)
        #expect(run.outcomeCode == AnalysisFailureCode.providerRejected.rawValue)
        #expect(run.listenerFailure == AnalysisProviderFailure.keyRequired.rawValue)
        #expect(run.finishedAt != nil)
        #expect(environment.runs.latestDispatched(feature: .adDetection, episodeID: transcript.episodeID) == nil)
        // What was sent before the key went counts, before the run ends.
        #expect(environment.usage == [.init(provider: .google, inputTokens: 420, outputTokens: 36, runID: run.id)])
        #expect(environment.usageRunStates == [.dispatched])
        #expect(try await store.automaticReplayError(for: transcript) == nil)

        // The episode's next run clears the mark.
        environment.route = .keyRequired(.noKey)
        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(!store.endedForKeyRemoval(episodeID: transcript.episodeID))
        #expect(await waitUntil { !store.hasActiveJob })
        #expect(environment.presentedReasons == [.noKey])
    }

    @Test("Removing a key cancels the active run on that provider only")
    func removingKeyCancelsRunOnThatProvider() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .hold
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let appModel = OpenCastAppModel(adAnalyses: store, allowsAutomaticFeedRefresh: false)
        let google = makeTranscriptDocument(episodeID: "ad-cancel-on-provider")

        store.startAnalysis(transcript: google, modelContext: context)
        #expect(await waitUntil { environment.sends.count == 1 })
        #expect(store.activeDirectProvider == .google)
        appModel.cancelAnalysisRuns(onProvider: .openai)
        #expect(store.isRunning(for: google.episodeID))

        appModel.cancelAnalysisRuns(onProvider: .google)
        #expect(await waitUntil { !store.hasActiveJob })
        #expect(environment.latestRun?.state == .failed)
        #expect(store.record(for: google.episodeID)?.failureKind == .keyRequiredNoKey)
        #expect(store.activeDirectProvider == nil)

        environment.route = .trial
        let trial = makeTranscriptDocument(episodeID: "ad-cancel-trial")
        store.startAnalysis(transcript: trial, modelContext: context)
        #expect(await waitUntil { environment.sends.count == 2 })
        #expect(store.activeDirectProvider == nil)
        appModel.cancelAnalysisRuns(onProvider: .google)
        #expect(store.isRunning(for: trial.episodeID))
        store.cancelActiveRun(reason: .listener)
        #expect(await waitUntil { !store.hasActiveJob })
    }

    @Test("Normalizes tiny transcript overlap before the pipeline")
    func normalizesTinyTranscriptOverlapBeforePipeline() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        var transcript = makeTranscriptDocument(episodeID: "ad-overlap")
        transcript.segments = [
            OpenCastTranscriptSegment(
                id: 1922,
                start: 8755.3935546875,
                end: 8760.3935546875,
                text: "Only that the goal is to tamper with numerical results.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1923,
                start: 8760.3916015625,
                end: 8767.3916015625,
                text: "not unauthorized access, not malware propagation, or other common malware objectives.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(environment.sends.firstSegments.map(\.id) == [0, 1])
        #expect(store.record(for: transcript.episodeID)?.transcriptSegmentCount == 2)
        #expect(store.record(for: transcript.episodeID)?.spanCount == 0)
    }

    @Test("Drops blank transcript segments before the pipeline")
    func dropsBlankTranscriptSegmentsBeforePipeline() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(fileStore: fileStore, environment: environment)
        var transcript = makeTranscriptDocument(episodeID: "ad-blank-segments")
        transcript.segments = [
            OpenCastTranscriptSegment(
                id: 40,
                start: 0,
                end: 4,
                text: "  Welcome back to the show.  ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 41,
                start: 4,
                end: 5,
                text: "   ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 42,
                start: 5,
                end: 6,
                text: "\n\t",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 43,
                start: 6,
                end: 11,
                text: "Back to the episode.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let segments = environment.sends.firstSegments
        #expect(segments.map(\.id) == [0, 1])
        #expect(segments.map(\.text) == [
            "Welcome back to the show.",
            "Back to the episode."
        ])
        #expect(record.transcriptSegmentCount == 2)
        #expect(document.transcriptSegmentCount == 2)
        #expect(document.transcriptFingerprint == fileStore.transcriptFingerprint(for: transcript))
    }

    @Test("Blank-only transcript is unavailable for analysis")
    func blankOnlyTranscriptIsUnavailableForAnalysis() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        var transcript = makeTranscriptDocument(episodeID: "ad-blank-only")
        transcript.segments = [
            OpenCastTranscriptSegment(
                id: 80,
                start: 0,
                end: 2,
                text: " \n\t ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")

        if case .unavailable(let message) = store.jobState(for: transcript) {
            #expect(message == "Transcript has no segments.")
        } else {
            Issue.record("Expected unavailable state for blank-only transcript.")
        }

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob
        })

        #expect(environment.sends.count == 0)
        #expect(environment.resolvedRunIDs.isEmpty)
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(store.lastErrorMessage(for: transcript.episodeID) == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
    }

    @Test("Without a run environment nothing starts, and an episode without a record stays ready")
    func missingRunEnvironmentStartsNothing() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = EpisodeAdAnalysisStore(
            client: UnpolledAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-no-environment")

        #expect(!store.canStartAnalysis)
        #expect(store.analysisStartUnavailableMessage == EpisodeAdAnalysisError.clientDisabled.localizedDescription)
        guard case .ready = store.jobState(for: transcript) else {
            Issue.record("The route is decided when a run starts; the episode stays ready.")
            return
        }

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(!store.hasActiveJob)
        #expect(store.lastErrorMessage(for: transcript.episodeID) == EpisodeAdAnalysisError.clientDisabled.localizedDescription)
    }

    @Test("App model refuses ad analysis for non-completed transcript records")
    func appModelRefusesAdAnalysisForNonCompletedTranscriptRecords() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let environment = ScriptedAdAnalysisRunEnvironment()
        let adAnalyses = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory),
            environment: environment
        )
        let appModel = OpenCastAppModel(
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-incomplete-transcript")

        _ = try writeTranscript(
            transcript,
            fileStore: transcriptFileStore,
            modelContext: context,
            state: .interrupted
        )
        transcriptions.load(modelContext: context)

        if case .unavailable(let message) = adAnalyses.jobState(
            for: transcript,
            transcriptState: transcriptions.record(for: transcript.episodeID)?.state
        ) {
            #expect(message == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
        } else {
            Issue.record("Expected unavailable state for incomplete transcript.")
        }

        appModel.analyzeEpisodeTranscript(transcript, modelContext: context)

        #expect(adAnalyses.runEnvironment === environment)
        #expect(environment.sends.count == 0)
        #expect(adAnalyses.record(for: transcript.episodeID) == nil)
        #expect(!adAnalyses.hasActiveJob)
        #expect(adAnalyses.lastErrorMessage(for: transcript.episodeID) == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
    }

    @Test("The app model's Detect Ads opens the key screen when the run needs the listener's key")
    func appModelDetectAdsPresentsKeyScreen() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.route = .keyRequired(.noKey)
        let adAnalyses = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory),
            environment: environment
        )
        let appModel = OpenCastAppModel(
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-app-key-screen")
        _ = try writeTranscript(transcript, fileStore: transcriptFileStore, modelContext: context)
        transcriptions.load(modelContext: context)

        appModel.analyzeEpisodeTranscript(transcript, modelContext: context)

        #expect(await waitUntil {
            !adAnalyses.hasActiveJob && adAnalyses.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(adAnalyses.record(for: transcript.episodeID)?.failureKind == .keyRequiredNoKey)
        #expect(environment.presentedReasons == [.noKey])
    }

    @Test("The app model gives a store without a run environment the live one")
    func appModelConfiguresLiveRunEnvironment() throws {
        let adAnalyses = EpisodeAdAnalysisStore(
            client: UnpolledAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let runs = AnalysisRunRecordStore(directory: try makeTemporaryDirectory())
        let appModel = OpenCastAppModel(adAnalyses: adAnalyses, analysisRuns: runs, allowsAutomaticFeedRefresh: false)

        let environment = try #require(adAnalyses.runEnvironment as? EpisodeAdAnalysisLiveRunEnvironment)
        #expect(environment.runs === runs)
        #expect(environment.adDetectionPolicyRevision == appModel.analysisPolicy.snapshot.bundle.features.adDetection.revision)
        #expect(adAnalyses.canStartAnalysis)
    }

    @Test("Active analysis reports running and blocks another analysis")
    func activeAnalysisReportsRunningAndBlocksAnotherAnalysis() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.gate = gate
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let firstTranscript = makeTranscriptDocument(episodeID: "ad-active-first")
        let secondTranscript = makeTranscriptDocument(episodeID: "ad-active-second")

        store.startAnalysis(transcript: firstTranscript, modelContext: context)

        #expect(store.hasActiveJob)
        if case .running = store.jobState(for: firstTranscript) {
        } else {
            Issue.record("Expected first analysis to be running.")
        }

        store.startAnalysis(transcript: secondTranscript, modelContext: context)

        #expect(store.record(for: secondTranscript.episodeID) == nil)
        #expect(store.lastErrorMessage(for: secondTranscript.episodeID) == EpisodeAdAnalysisError.anotherJobActive.localizedDescription)

        await gate.release()

        #expect(await waitUntil {
            store.record(for: firstTranscript.episodeID)?.state == .completed
        })
        #expect(environment.sends.count == 1)
        #expect(!store.hasActiveJob)
    }

    @Test("An active job never marks other episodes as running")
    func activeJobNeverMarksOtherEpisodesRunning() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.gate = gate
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let runningTranscript = makeTranscriptDocument(episodeID: "ad-running-first")
        let otherTranscript = makeTranscriptDocument(episodeID: "ad-idle-second")

        store.startAnalysis(transcript: runningTranscript, modelContext: context)
        #expect(store.isRunning(for: runningTranscript.episodeID))

        // The uninvolved episode was never queued: while the first job is in
        // flight it must offer detection, not report that run as its own.
        #expect(!store.isRunning(for: otherTranscript.episodeID))
        #expect(store.analysisProgress(for: otherTranscript.episodeID) == nil)
        if case .ready = store.jobState(for: otherTranscript) {
        } else {
            Issue.record("Expected the uninvolved episode to stay ready, got \(store.jobState(for: otherTranscript))")
        }

        await gate.release()

        #expect(await waitUntil {
            !store.hasActiveJob
        })
    }

    @Test("Store reports running while normalization and fingerprint preparation is held")
    func reportsRunningDuringHeldPreparation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment,
            preparationGate: {
                await gate.wait()
            }
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-held-preparation")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(store.hasActiveJob)
        #expect(store.record(for: transcript.episodeID) == nil)
        if case .running = store.jobState(for: transcript) {
        } else {
            Issue.record("Expected running while preparation is held.")
        }
        #expect(environment.sends.count == 0)

        await gate.release()

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
    }

    @Test("Cancellation during held preparation performs no request or persistence")
    func cancellationDuringHeldPreparation() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment,
            preparationGate: {
                await gate.wait()
            }
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-cancelled-preparation")

        store.startAnalysis(transcript: transcript, modelContext: context)
        store.cancelActiveRun(reason: .listener)
        await gate.release()

        #expect(await waitUntil {
            !store.hasActiveJob
        })
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(environment.resolvedRunIDs.isEmpty)
        #expect(environment.sends.count == 0)
        #expect(environment.runs.records(limit: 10).isEmpty)
    }

    @Test("Preparation failure clears running state and surfaces the error")
    func preparationFailureSurfacesError() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let gate = AsyncTestGate()
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment,
            preparationGate: {
                await gate.wait()
                throw EpisodeAdAnalysisError.transcriptNotCompleted
            }
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-failed-preparation")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(store.hasActiveJob)
        await gate.release()

        #expect(await waitUntil {
            !store.hasActiveJob
        })
        #expect(
            store.lastErrorMessage(for: transcript.episodeID)
                == EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription
        )
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(environment.sends.count == 0)
    }

    @Test("Nuke cancels the active run, ends its run record and removes the running record")
    func nukeCancelsActiveAnalysisAndRemovesRunningRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .hold
        let store = makeStore(fileStore: fileStore, environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "ad-active-nuke")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil { environment.sends.count == 1 })

        try await store.nukeAllAnalyses(modelContext: context)

        #expect(!store.hasActiveJob)
        #expect(store.records.isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileStore.analysesDirectory.path))
        #expect(environment.latestRun?.state == .cancelled)
    }

    @Test("Backend configuration resolves debug environment and disabled release config")
    func backendConfigurationResolvesDebugEnvironmentAndDisabledReleaseConfig() {
        #if DEBUG
        let defaultDebug = AdAnalysisBackendConfiguration.debug(environment: [:])
        #expect(defaultDebug.workerBaseURL.absoluteString == "https://ad-analysis.example.com/development")
        #expect(defaultDebug.isEnabled)
        #expect(defaultDebug.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.development
        ))

        let overrideDebug = AdAnalysisBackendConfiguration.debug(environment: [
            "OPENCAST_AD_ANALYSIS_BASE_URL": "  https://staging.example  ",
            "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN": "  test-token  "
        ])
        #expect(overrideDebug.workerBaseURL.absoluteString == "https://staging.example")
        #expect(overrideDebug.authentication == .bearer(clientToken: "test-token"))
        #expect(overrideDebug.isEnabled)

        let invalidOverride = AdAnalysisBackendConfiguration.debug(environment: [
            "OPENCAST_AD_ANALYSIS_BASE_URL": "worker.example",
            "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN": "   "
        ])
        #expect(invalidOverride.workerBaseURL.absoluteString == "https://ad-analysis.example.com/development")
        #expect(invalidOverride.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.development
        ))
        #endif

        let release = AdAnalysisBackendConfiguration.production
        #expect(release.workerBaseURL.absoluteString == "https://ad-analysis.example.com")
        #expect(release.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.production
        ))
        #expect(release.isEnabled)

        let prodStaging = AdAnalysisBackendConfiguration.prodStaging
        #expect(prodStaging.workerBaseURL.absoluteString == "https://ad-analysis.example.com/prod-staging")
        #expect(prodStaging.authentication == .appAttest(
            keychainService: AdAnalysisAppAttestKeychainServices.prodStaging
        ))
        #expect(prodStaging.isEnabled)
    }

    @Test("Ad analysis record is local-only but included in full schema")
    func adAnalysisRecordIsLocalOnlyButIncludedInFullSchema() {
        #expect(OpenCastModelContainerFactory.localSchema.entitiesByName["EpisodeAdAnalysisRecord"] != nil)
        #expect(OpenCastModelContainerFactory.fullSchema.entitiesByName["EpisodeAdAnalysisRecord"] != nil)
        #expect(OpenCastModelContainerFactory.syncedSchema.entitiesByName["EpisodeAdAnalysisRecord"] == nil)
    }

    @Test("Marks completed analysis stale when transcript fingerprint inputs change")
    func marksCompletedAnalysisStaleWhenTranscriptFingerprintInputsChange() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory))
        let transcript = makeTranscriptDocument(episodeID: "ad-stale")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let updatedTranscript = makeTranscriptDocument(
            episodeID: "ad-stale",
            updatedAt: transcript.updatedAt.addingTimeInterval(30),
            extraSegmentText: "new segment"
        )

        if case .completed(_, let isStale) = store.jobState(for: updatedTranscript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state.")
        }
    }

    @Test("Marks completed analysis stale when only transcript text changes")
    func marksCompletedAnalysisStaleWhenOnlyTranscriptTextChanges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory))
        let transcript = makeTranscriptDocument(episodeID: "ad-fingerprint-stale")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let updatedTranscript = makeTranscriptDocument(
            episodeID: "ad-fingerprint-stale",
            updatedAt: transcript.updatedAt,
            sponsorSegmentText: "Different sponsor copy with the same segment count."
        )

        if case .completed(_, let isStale) = store.jobState(for: updatedTranscript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state.")
        }
    }

    @Test("Marks completed analysis stale when stored transcript state is not completed")
    func marksCompletedAnalysisStaleWhenStoredTranscriptStateIsNotCompleted() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory))
        let transcript = makeTranscriptDocument(episodeID: "ad-state-stale")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let record = try #require(store.record(for: transcript.episodeID))
        record.transcriptState = .interrupted

        if case .completed(_, let isStale) = store.jobState(for: transcript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state.")
        }
    }

    @Test("Marks completed ads_only analysis outdated and re-run overwrites it")
    func marksCompletedAdsOnlyAnalysisOutdatedAndRerunOverwrites() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory))
        let transcript = makeTranscriptDocument(episodeID: "ad-policy-stale")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let record = try #require(store.record(for: transcript.episodeID))
        // Rewrite the stored analysis as a legacy ads_only result whose
        // transcript inputs are still perfectly current.
        record.policy = "ads_only"
        var document = try #require(store.document(for: transcript.episodeID))
        document.policy = "ads_only"
        let relativePath = try #require(record.analysisRelativePath)
        try EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
            .write(document, relativePath: relativePath)

        if case .completed(_, let isStale) = store.jobState(for: transcript) {
            #expect(isStale)
        } else {
            Issue.record("Expected completed stale state for ads_only policy.")
        }
        #expect(!store.isCurrentAnalysisDocument(document, for: transcript))

        // A manual re-run overwrites the outdated document and clears staleness.
        await startAndWait(store: store, transcript: transcript, modelContext: context)
        if case .completed(_, let isStale) = store.jobState(for: transcript) {
            #expect(!isStale)
        } else {
            Issue.record("Expected completed current state after re-run.")
        }
        let rerunDocument = try #require(store.document(for: transcript.episodeID))
        #expect(EpisodeAdAnalysisContract.supports(policy: rerunDocument.policy))
        #expect(store.isCurrentAnalysisDocument(rerunDocument, for: transcript))
    }

    @Test("Supported cloud analyses stay current after transcript disk round trip", arguments: ["promo_ad_breaks_v2", "promo_ad_breaks_v3"])
    func cloudImportedAnalysisStaysCurrentAfterTranscriptRoundTrip(policy: String) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory))
        // The cloud pass maps the analysis from the in-memory transcript,
        // whose minted `updatedAt` can carry fractional seconds that the
        // `.iso8601` disk round trip drops.
        let inMemoryTranscript = makeTranscriptDocument(
            episodeID: "ad-cloud-round-trip",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000.742)
        )
        let success = OpenCastRemoteTranscriptionAdAnalysisSuccess(
            model: "gemini-3.5-flash",
            policy: policy,
            spans: [OpenCastRemoteTranscriptionAdAnalysisSpan(
                kind: "host_read_ad",
                label: "Sponsor",
                startSegmentID: 1,
                endSegmentID: 1,
                startTime: 5,
                endTime: 12,
                confidence: 0.9,
                evidenceQuote: "brought to you by"
            )],
            warnings: []
        )
        let analysisDocument = try EpisodeRemoteAdAnalysisMapper.document(
            from: success,
            transcript: inMemoryTranscript,
            requestID: "job-cloud-round-trip"
        )

        try store.importCompletedAnalysis(analysisDocument, modelContext: context)

        let reloadedTranscript = makeTranscriptDocument(
            episodeID: "ad-cloud-round-trip",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        if case .completed(_, let isStale) = store.jobState(for: reloadedTranscript) {
            #expect(!isStale)
        } else {
            Issue.record("Expected completed current state after cloud import.")
        }
    }

    @Test("Current document check requires matching fingerprint metadata")
    func currentDocumentCheckRequiresMatchingFingerprintMetadata() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let store = makeStore(fileStore: EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory))
        let transcript = makeTranscriptDocument(episodeID: "ad-current-document")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let analysisDocument = try #require(store.document(for: transcript.episodeID))

        #expect(store.isCurrentAnalysisDocument(analysisDocument, for: transcript))
        var interruptedStateDocument = analysisDocument
        interruptedStateDocument.transcriptState = .interrupted
        #expect(!store.isCurrentAnalysisDocument(interruptedStateDocument, for: transcript))

        let textChangedTranscript = makeTranscriptDocument(
            episodeID: transcript.episodeID,
            updatedAt: transcript.updatedAt,
            sponsorSegmentText: "Same timing and segment count but different words."
        )
        #expect(!store.isCurrentAnalysisDocument(analysisDocument, for: textChangedTranscript))

        let updatedTranscript = makeTranscriptDocument(
            episodeID: transcript.episodeID,
            updatedAt: transcript.updatedAt.addingTimeInterval(30)
        )
        #expect(!store.isCurrentAnalysisDocument(analysisDocument, for: updatedTranscript))

        let segmentCountChangedTranscript = makeTranscriptDocument(
            episodeID: transcript.episodeID,
            updatedAt: transcript.updatedAt,
            extraSegmentText: "Extra transcript segment."
        )
        #expect(!store.isCurrentAnalysisDocument(analysisDocument, for: segmentCountChangedTranscript))
    }

    @Test("Deletes ad analysis record and sidecar")
    func deletesAdAnalysisRecordAndSidecar() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = makeStore(fileStore: fileStore)
        let transcript = makeTranscriptDocument(episodeID: "ad-delete")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let relativePath = try #require(store.record(for: transcript.episodeID)?.analysisRelativePath)
        #expect(fileStore.documentExists(relativePath: relativePath))
        let orphanRelativePath = "\(EpisodeAdAnalysisFileStore.directoryName)/\(fileStore.safeStem(transcript.episodeID))/orphan.json"
        let orphanURL = fileStore.fileURL(relativePath: orphanRelativePath)
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: orphanURL)
        #expect(fileStore.documentExists(relativePath: orphanRelativePath))

        store.deleteAnalysis(episodeID: transcript.episodeID, modelContext: context)

        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(!fileStore.documentExists(relativePath: relativePath))
        #expect(!fileStore.documentExists(relativePath: orphanRelativePath))
    }

    @Test("App model transcript deletion removes transcript and ad analysis sidecars")
    func appModelTranscriptDeletionRemovesTranscriptAndAdAnalysisSidecars() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let adAnalyses = makeStore(fileStore: adAnalysisFileStore)
        let appModel = OpenCastAppModel(
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-app-delete-transcript")
        let transcriptRelativePath = try writeTranscript(
            transcript,
            fileStore: transcriptFileStore,
            modelContext: context
        )
        transcriptions.load(modelContext: context)
        await startAndWait(store: adAnalyses, transcript: transcript, modelContext: context)
        let analysisRelativePath = try #require(adAnalyses.record(for: transcript.episodeID)?.analysisRelativePath)
        #expect(transcriptFileStore.documentExists(relativePath: transcriptRelativePath))
        #expect(adAnalysisFileStore.documentExists(relativePath: analysisRelativePath))

        appModel.deleteEpisodeTranscript(episodeID: transcript.episodeID, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).isEmpty)
        #expect(!transcriptFileStore.documentExists(relativePath: transcriptRelativePath))
        #expect(!adAnalysisFileStore.documentExists(relativePath: analysisRelativePath))
        #expect(appModel.transcriptions.record(for: transcript.episodeID) == nil)
        #expect(appModel.adAnalyses.record(for: transcript.episodeID) == nil)
    }

    @Test("Deletes ad analyses for one podcast and preserves other podcasts")
    func deletesAdAnalysesForPodcast() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = makeStore(fileStore: fileStore)
        let firstTranscript = makeTranscriptDocument(
            episodeID: "ad-podcast-delete-1",
            podcastID: "https://example.com/delete.xml"
        )
        let secondTranscript = makeTranscriptDocument(
            episodeID: "ad-podcast-delete-2",
            podcastID: "https://example.com/delete.xml"
        )
        let preservedTranscript = makeTranscriptDocument(
            episodeID: "ad-podcast-preserved",
            podcastID: "https://example.com/preserved.xml"
        )

        await startAndWait(store: store, transcript: firstTranscript, modelContext: context)
        await startAndWait(store: store, transcript: secondTranscript, modelContext: context)
        await startAndWait(store: store, transcript: preservedTranscript, modelContext: context)
        let firstPath = try #require(store.record(for: firstTranscript.episodeID)?.analysisRelativePath)
        let secondPath = try #require(store.record(for: secondTranscript.episodeID)?.analysisRelativePath)
        let preservedPath = try #require(store.record(for: preservedTranscript.episodeID)?.analysisRelativePath)
        let orphanRelativePath = "\(EpisodeAdAnalysisFileStore.directoryName)/\(fileStore.safeStem(firstTranscript.episodeID))/orphan.json"
        let orphanURL = fileStore.fileURL(relativePath: orphanRelativePath)
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: orphanURL)
        #expect(fileStore.documentExists(relativePath: orphanRelativePath))

        try store.deleteAnalyses(
            forPodcastID: "https://example.com/delete.xml",
            modelContext: context
        )

        #expect(store.record(for: firstTranscript.episodeID) == nil)
        #expect(store.record(for: secondTranscript.episodeID) == nil)
        #expect(store.record(for: preservedTranscript.episodeID)?.state == .completed)
        #expect(!fileStore.documentExists(relativePath: firstPath))
        #expect(!fileStore.documentExists(relativePath: secondPath))
        #expect(!fileStore.documentExists(relativePath: orphanRelativePath))
        #expect(fileStore.documentExists(relativePath: preservedPath))
    }

    @Test("App model unsubscribe removes transcript and ad analysis sidecars for podcast")
    func appModelUnsubscribeRemovesTranscriptAndAdAnalysisSidecarsForPodcast() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let transcriptions = EpisodeTranscriptionStore(fileStore: transcriptFileStore)
        let adAnalyses = makeStore(fileStore: adAnalysisFileStore)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            allowsAutomaticFeedRefresh: false
        )
        let removedFeedURL = "https://example.com/app-unsubscribe-remove.xml"
        let keptFeedURL = "https://example.com/app-unsubscribe-keep.xml"
        let removedTranscript = makeTranscriptDocument(
            episodeID: "ad-app-unsubscribe-remove",
            podcastID: removedFeedURL
        )
        let keptTranscript = makeTranscriptDocument(
            episodeID: "ad-app-unsubscribe-keep",
            podcastID: keptFeedURL
        )
        let removedTranscriptPath = try writeTranscript(
            removedTranscript,
            fileStore: transcriptFileStore,
            modelContext: context
        )
        let keptTranscriptPath = try writeTranscript(
            keptTranscript,
            fileStore: transcriptFileStore,
            modelContext: context
        )
        transcriptions.load(modelContext: context)
        await startAndWait(store: adAnalyses, transcript: removedTranscript, modelContext: context)
        await startAndWait(store: adAnalyses, transcript: keptTranscript, modelContext: context)
        let removedAnalysisPath = try #require(adAnalyses.record(for: removedTranscript.episodeID)?.analysisRelativePath)
        let keptAnalysisPath = try #require(adAnalyses.record(for: keptTranscript.episodeID)?.analysisRelativePath)

        await appModel.unsubscribe(feedURL: removedFeedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).map(\.episodeID) == [keptTranscript.episodeID])
        #expect(try context.fetch(FetchDescriptor<EpisodeAdAnalysisRecord>()).map(\.episodeID) == [keptTranscript.episodeID])
        #expect(!transcriptFileStore.documentExists(relativePath: removedTranscriptPath))
        #expect(transcriptFileStore.documentExists(relativePath: keptTranscriptPath))
        #expect(!adAnalysisFileStore.documentExists(relativePath: removedAnalysisPath))
        #expect(adAnalysisFileStore.documentExists(relativePath: keptAnalysisPath))
        #expect(appModel.transcriptions.record(for: removedTranscript.episodeID) == nil)
        #expect(appModel.transcriptions.record(for: keptTranscript.episodeID)?.state == .completed)
        #expect(appModel.adAnalyses.record(for: removedTranscript.episodeID) == nil)
        #expect(appModel.adAnalyses.record(for: keptTranscript.episodeID)?.state == .completed)
    }

    @Test("Nuke removes all ad analysis records and sidecars")
    func nukeRemovesAllAdAnalysisRecordsAndSidecars() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = makeStore(fileStore: fileStore)
        let firstTranscript = makeTranscriptDocument(episodeID: "ad-nuke-1")
        let secondTranscript = makeTranscriptDocument(episodeID: "ad-nuke-2")

        await startAndWait(store: store, transcript: firstTranscript, modelContext: context)
        await startAndWait(store: store, transcript: secondTranscript, modelContext: context)
        #expect(FileManager.default.fileExists(atPath: fileStore.analysesDirectory.path))

        try await store.nukeAllAnalyses(modelContext: context)

        #expect(store.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileStore.analysesDirectory.path))
    }

    @Test("Load marks completed analysis failed when sidecar is missing")
    func loadMarksCompletedAnalysisFailedWhenSidecarIsMissing() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let store = makeStore(fileStore: fileStore)
        let transcript = makeTranscriptDocument(episodeID: "ad-missing-sidecar")

        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let relativePath = try #require(store.record(for: transcript.episodeID)?.analysisRelativePath)
        try fileStore.delete(relativePath: relativePath)
        guard case .completed(_, isStale: true) = store.jobState(for: transcript) else {
            Issue.record("A completed analysis still requires its output document.")
            return
        }

        let reloadedStore = makeStore(fileStore: fileStore)
        reloadedStore.load(modelContext: context)

        let record = try #require(reloadedStore.record(for: transcript.episodeID))
        #expect(record.state == .failed)
        #expect(record.errorMessage == "Promo/ad analysis document is missing.")
    }

    @Test("Validation exhaustion pauses automatic retries across relaunch until the input or the bundle revision changes")
    func validationReplayPersistence() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let files = EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .unverifiableBreak
        let store = makeStore(fileStore: files, environment: environment)
        let transcript = makeTranscriptDocument(episodeID: "replay-persistence")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(store.record(for: transcript.episodeID)?.failureKind == .validationExhausted)
        #expect(environment.sends.count(of: .adWindow(index: 0)) == 1)
        #expect(environment.sends.count(of: .adRepair(index: 0)) == 1)
        #expect(environment.latestRun?.outcomeCode == "ad_analysis_incomplete")
        #expect(environment.latestRun?.listenerFailure == AnalysisProviderFailure.malformedAnswer.rawValue)

        let reloaded = makeStore(fileStore: files, environment: environment)
        reloaded.load(modelContext: context)
        #expect(try await reloaded.automaticReplayError(for: transcript) != nil)
        var reimported = transcript
        reimported.updatedAt = .now
        #expect(try await reloaded.automaticReplayError(for: reimported) != nil)
        var changed = transcript
        changed.sourceFileSHA256 = "different-recording"
        #expect(try await reloaded.automaticReplayError(for: changed) == nil)
        changed = transcript
        changed.segments[0].text += " New source text."
        #expect(try await reloaded.automaticReplayError(for: changed) == nil)
        let revision = environment.adDetectionPolicyRevision
        environment.adDetectionPolicyRevision = "a-later-revision"
        #expect(try await reloaded.automaticReplayError(for: transcript) == nil)
        environment.adDetectionPolicyRevision = revision

        let sendsBeforeAutomatic = environment.sends.count
        reloaded.startAnalysis(transcript: transcript, retryFailed: false, modelContext: context)
        #expect(await waitUntil { !reloaded.isRunning(for: transcript.episodeID) })
        #expect(environment.sends.count == sendsBeforeAutomatic)

        environment.answer = .sponsorRead
        reloaded.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil { reloaded.record(for: transcript.episodeID)?.state == .completed })
        #expect(environment.sends.count == sendsBeforeAutomatic + 1)
        #expect(try await reloaded.automaticReplayError(for: transcript) == nil)
    }

    @Test("A failed replacement preserves the last valid ad document")
    func replacementFailurePreservesGoodAnalysis() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let transcript = makeTranscriptDocument(episodeID: "retain-good-analysis")
        await startAndWait(store: store, transcript: transcript, modelContext: context)
        let original = try #require(store.document(for: transcript.episodeID))

        environment.answer = .unverifiableBreak
        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil { environment.sends.count == 3 && !store.isRunning(for: transcript.episodeID) })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.state == .completed)
        #expect(record.failureKind == .validationExhausted)
        #expect(store.document(for: transcript.episodeID) == original)
        #expect(store.lastErrorMessage(for: transcript.episodeID) != nil)
    }

    @Test("A successful rerun clears the stored failure kind")
    func successfulRerunClearsFailureKind() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let environment = ScriptedAdAnalysisRunEnvironment()
        environment.answer = .failure(.rejected(status: 400), status: 400, listener: .invalidKey)
        let store = makeStore(
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory()),
            environment: environment
        )
        let transcript = makeTranscriptDocument(episodeID: "ad-failure-clears")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(store.record(for: transcript.episodeID)?.failureKind == .providerRejectedKey)

        environment.answer = .sponsorRead
        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == nil)
        #expect(record.errorMessage == nil)
    }

    #if DEBUG
    @Test("URLSession bearer client decodes a running poll")
    func urlSessionBearerClientDecodesRunningPoll() async throws {
        let pollTransport = FakeEpisodeAdAnalysisHTTPTransport(
            statusCode: 202,
            body: Data(#"{"job_id":"fingerprint","state":"running","poll_after_seconds":10}"#.utf8)
        )
        let pollClient = URLSessionEpisodeAdAnalysisClient(
            configuration: bearerConfiguration,
            transport: pollTransport
        )

        let pollOutcome = try await pollClient.pollJob(id: "fingerprint")
        let pollRequest = try #require(pollTransport.lastRequest)
        let pollBody = try #require(pollRequest.httpBody)
        let decodedPollBody = try JSONDecoder().decode(EpisodeAdAnalysisJobPollRequest.self, from: pollBody)
        #expect(pollOutcome == .running(pollAfter: 10))
        #expect(pollRequest.url?.path == "/v1/ad-analysis/jobs/fingerprint")
        #expect(pollRequest.value(forHTTPHeaderField: "authorization") == "Bearer test-token")
        #expect(pollRequest.timeoutInterval == URLSessionEpisodeAdAnalysisClient.pollTimeout)
        #expect(decodedPollBody == EpisodeAdAnalysisJobPollRequest(jobID: "fingerprint"))
    }

    @Test("URLSession client decodes a completed poll and an unknown span kind as .unknown instead of throwing")
    func urlSessionClientDecodesCompletedPollWithUnknownSpanKind() async throws {
        let responseBody = Data("""
        {
          "schema_version": 1,
          "request_id": "client-unknown-kind",
          "model": "gemini-2.5-flash-lite",
          "policy": "ads_only",
          "spans": [
            {
              "kind": "subliminal_ad",
              "label": "Future Kind",
              "start_segment_id": 4,
              "end_segment_id": 6,
              "start_time": 10.5,
              "end_time": 21.25,
              "confidence": 0.91,
              "evidence_quote": "sponsor read"
            }
          ],
          "warnings": [],
          "usage": {
            "prompt_token_count": 123,
            "candidates_token_count": 45,
            "total_token_count": 168
          }
        }
        """.utf8)
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: bearerConfiguration,
            transport: FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: responseBody)
        )

        let outcome = try await client.pollJob(id: "fingerprint")
        guard case .completed(let response) = outcome else {
            Issue.record("Expected a completed job.")
            return
        }
        #expect(response.spans.first?.kind == .unknown)
        #expect(response.usage?.totalTokenCount == 168)
    }

    @Test("URLSession client decodes structured HTTP errors")
    func urlSessionClientDecodesStructuredHTTPErrors() async throws {
        let errorBody = Data("""
        {
          "error": "job_not_found",
          "detail": "no such job"
        }
        """.utf8)
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: bearerConfiguration,
            transport: FakeEpisodeAdAnalysisHTTPTransport(statusCode: 404, body: errorBody)
        )

        await #expect(throws: EpisodeAdAnalysisHTTPError(
            statusCode: 404,
            code: "job_not_found",
            detail: "no such job"
        )) {
            try await client.pollJob(id: "fingerprint")
        }
    }

    @Test("URLSession client falls back to HTTP status for unstructured errors")
    func urlSessionClientFallsBackToHTTPStatusForUnstructuredErrors() async {
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: bearerConfiguration,
            transport: FakeEpisodeAdAnalysisHTTPTransport(
                statusCode: 502,
                body: Data("upstream unavailable".utf8)
            )
        )

        await #expect(throws: EpisodeAdAnalysisHTTPError(
            statusCode: 502,
            code: "http_502",
            detail: nil
        )) {
            try await client.pollJob(id: "fingerprint")
        }
    }

    private var bearerConfiguration: AdAnalysisBackendConfiguration {
        AdAnalysisBackendConfiguration(
            workerBaseURL: URL(string: "https://worker.example")!,
            authentication: .bearer(clientToken: "test-token"),
            isEnabled: true
        )
    }
    #endif

    @Test("URLSession App Attest client envelopes the poll and rotates on recoverable key failure")
    func urlSessionAppAttestClientEnvelopesPollAndRotatesOnRecoverableKeyFailure() async throws {
        let keychainService = "com.connor.opencast.tests.ad-analysis-security.\(UUID().uuidString)"
        let keychain = AppAttestKeychain(service: keychainService)
        try? keychain.deleteAll()
        defer {
            try? keychain.deleteAll()
        }

        let transport = AppAttestRoutingHTTPTransport(pollResponses: [
            .error(statusCode: 401, code: "unknown_key"),
            .running(jobID: "fingerprint")
        ])
        let appAttestService = FakeAppAttestService(
            isSupported: true,
            keyIDs: ["fake-key-1", "fake-key-2"]
        )
        let client = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: keychainService),
                isEnabled: true
            ),
            transport: transport,
            appAttestService: appAttestService
        )

        let outcome = try await client.pollJob(id: "fingerprint")
        let pollPath = "/v1/ad-analysis/jobs/fingerprint"
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(EpisodeAdAnalysisJobPollRequest(jobID: "fingerprint"))
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: pollPath,
            payload: payload
        )

        #expect(outcome == .running(pollAfter: 10))
        #expect(transport.pollRequestTimeouts == [
            URLSessionEpisodeAdAnalysisClient.pollTimeout,
            URLSessionEpisodeAdAnalysisClient.pollTimeout
        ])
        #expect(transport.requestPaths == [
            "/v1/app-attest/challenge",
            "/v1/app-attest/register",
            pollPath,
            "/v1/app-attest/challenge",
            "/v1/app-attest/register",
            pollPath
        ])
        #expect(appAttestService.generatedKeys == ["fake-key-1", "fake-key-2"])
        #expect(appAttestService.attestationKeyIDs == ["fake-key-1", "fake-key-2"])
        #expect(appAttestService.assertionKeyIDs == ["fake-key-1", "fake-key-2"])
        #expect(appAttestService.assertionClientDataHashes == [
            AppAttestRequestBinding.hexString(clientDataHash),
            AppAttestRequestBinding.hexString(clientDataHash)
        ])
        #expect(transport.registerRequests.map(\.keyID) == ["fake-key-1", "fake-key-2"])
        #expect(transport.pollEnvelopes.map(\.keyID) == ["fake-key-1", "fake-key-2"])
        #expect(transport.pollEnvelopes.map(\.payload) == [payload, payload])
        #expect(transport.pollEnvelopes.map(\.assertion) == [
            Data("assertion-fake-key-1".utf8).base64EncodedString(),
            Data("assertion-fake-key-2".utf8).base64EncodedString()
        ])
    }

    @Test("URLSession client enforces disabled and unsupported App Attest gates")
    func urlSessionClientEnforcesDisabledAndUnsupportedAppAttestGates() async {
        let disabledClient = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: "test.disabled"),
                isEnabled: false
            ),
            transport: FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: Data())
        )
        let unsupportedAppAttestClient = URLSessionEpisodeAdAnalysisClient(
            configuration: AdAnalysisBackendConfiguration(
                workerBaseURL: URL(string: "https://worker.example")!,
                authentication: .appAttest(keychainService: "test.unsupported"),
                isEnabled: true
            ),
            transport: FakeEpisodeAdAnalysisHTTPTransport(statusCode: 200, body: Data()),
            appAttestService: FakeAppAttestService(isSupported: false)
        )

        await #expect(throws: EpisodeAdAnalysisError.clientDisabled) {
            try await disabledClient.pollJob(id: "fingerprint")
        }
        await #expect(throws: EpisodeAdAnalysisError.appAttestUnavailable) {
            try await unsupportedAppAttestClient.pollJob(id: "fingerprint")
        }
    }

    @Test("A device run's failure reads back through the service's error body")
    func deviceFailureReadsThroughServiceErrorBody() throws {
        let failure = AnalysisFailure(feature: .adDetection, code: .adAnalysisIncomplete, status: 422, windowIndex: 0)
        let body = Data(JSONWriter.string(failure.errorJSON(policyRevision: "revision-a")).utf8)

        let error = EpisodeAdAnalysisHTTPError(statusCode: failure.status, body: body, listenerFailure: .malformedAnswer)

        #expect(error.statusCode == 422)
        #expect(error.code == "ad_analysis_incomplete")
        #expect(error.failure == OpenCastAdAnalysisFailure(
            category: .validationExhausted,
            retryDisposition: .explicitRetry,
            policyRevision: "revision-a"
        ))
        #expect(error.replayFailure?.suppressesAutomaticReplay == true)
        #expect(error.listenerFailure == .malformedAnswer)
        #expect(!error.isCapExceeded)
        #expect(EpisodeAdAnalysisHTTPError(statusCode: 503, body: Data("not json".utf8)).code == "http_503")
    }

    @Test("Canonical ad-analysis payload hash matches Worker binding fixture")
    func canonicalAdAnalysisPayloadHashMatchesWorkerBindingFixture() throws {
        let request = makeAPIRequest(requestID: "client-success")
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(request)
        let hash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/ad-analysis/transcript",
            payload: payload
        )

        #expect(
            payload ==
                #"{"episode_id":"client-episode","episode_title":"Client Episode","job_handle_version":1,"podcast_id":"https://example.com/feed.xml","podcast_title":"Client Podcast","request_id":"client-success","schema_version":1,"segments":[{"end":14,"id":4,"start":10.5,"text":"This part is brought to you by Example Sponsor."},{"end":21.25,"id":6,"start":14,"text":"Visit the sponsor for more details."}],"transcript":{"audio_duration":30,"fingerprint":"fingerprint","language_code":"en","model_identifier":"model","model_tree_sha256":"tree-sha","model_version":"v1","segment_count":2,"state":"completed","updated_at":"2026-05-28T20:26:40Z"}}"#
        )
        #expect(AppAttestRequestBinding.sha256Hex(Data(payload.utf8)) == "5a234ddb76bbe237d0c337eacf08ccd17c3109e4be96c62d03045889d933cee1")
        #expect(AppAttestRequestBinding.hexString(hash) == "9bac11efdc966dbf31898d1cea75d100615793a35402aae5c85291091e0726d6")

        var legacyRequest = request
        legacyRequest.jobHandleVersion = nil
        let legacyPayload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(legacyRequest)
        #expect(AppAttestRequestBinding.sha256Hex(Data(legacyPayload.utf8)) == "042cec13b4b71be3ec9b90671fe300c555507b7a04162fb248f4aa8ade69ee4a")
        #expect(AppAttestRequestBinding.hexString(AppAttestRequestBinding.clientDataHash(
            method: "POST", path: "/v1/ad-analysis/transcript", payload: legacyPayload
        )) == "e207f0dc7a4a4820ecf959aa727b7c0ecea7aa9d4e8eda2da8dfde45c472eec5")
    }

    @Test("Canonical poll payload hash matches Worker binding fixture")
    func canonicalPollPayloadHashMatchesWorkerBindingFixture() throws {
        let jobID = "fingerprint-123"
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(
            EpisodeAdAnalysisJobPollRequest(jobID: jobID)
        )
        let hash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/ad-analysis/jobs/\(jobID)",
            payload: payload
        )

        #expect(payload == #"{"job_id":"fingerprint-123"}"#)
        #expect(AppAttestRequestBinding.sha256Hex(Data(payload.utf8)) == "90da49444d4246a08405079cd75a63c2649a45850ceb8de7e00e2a78eb29a471")
        #expect(AppAttestRequestBinding.hexString(hash) == "c079e99784a3722a3b90e2523920fcca7c99a429ec3ad37e192acc8a87458d0a")
    }

    @Test("Ad-analysis request carries the feed's declared runtime only when known")
    func adAnalysisRequestCarriesDeclaredDurationOnlyWhenKnown() throws {
        var request = makeAPIRequest(requestID: "client-declared")
        #expect(try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(request).contains("declared_duration") == false)
        request.transcript.declaredDuration = 2471
        let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(request)
        #expect(payload.contains(#""audio_duration":30,"declared_duration":2471,"fingerprint":"fingerprint""#))
    }

    private func makeAPIRequest(requestID: String) -> EpisodeAdAnalysisAPIRequest {
        EpisodeAdAnalysisAPIRequest(
            schemaVersion: 1,
            requestID: requestID,
            episodeID: "client-episode",
            podcastID: "https://example.com/feed.xml",
            episodeTitle: "Client Episode",
            podcastTitle: "Client Podcast",
            transcript: EpisodeAdAnalysisAPITranscriptMetadata(
                languageCode: "en",
                audioDuration: 30,
                modelIdentifier: "model",
                modelVersion: "v1",
                modelTreeSHA256: "tree-sha",
                fingerprint: "fingerprint",
                updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                state: "completed",
                segmentCount: 2
            ),
            segments: [
                EpisodeAdAnalysisAPISegment(
                    id: 4,
                    start: 10.5,
                    end: 14,
                    text: "This part is brought to you by Example Sponsor."
                ),
                EpisodeAdAnalysisAPISegment(
                    id: 6,
                    start: 14,
                    end: 21.25,
                    text: "Visit the sponsor for more details."
                )
            ]
        )
    }

    private func writeTranscript(
        _ document: EpisodeTranscriptDocument,
        fileStore: EpisodeTranscriptFileStore,
        modelContext: ModelContext,
        state: EpisodeTranscriptState = .completed
    ) throws -> String {
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: document.episodeID, fingerprint: fingerprint)
        try fileStore.write(document, relativePath: relativePath)
        modelContext.insert(EpisodeTranscriptRecord(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            sourceAudioURL: document.sourceAudioURL,
            sourceFileByteCount: document.sourceFileByteCount,
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256,
            languageCode: document.languageCode,
            state: state,
            audioDuration: document.audioDuration,
            completedDuration: document.audioDuration,
            checkpointCount: document.checkpoints.count,
            transcriptRelativePath: relativePath,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        ))
        try modelContext.save()
        return relativePath
    }

    private func makeTranscriptDocument(
        episodeID: String,
        podcastID: String = "https://example.com/feed.xml",
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        sponsorSegmentText: String = "This episode is brought to you by Example Sponsor.",
        extraSegmentText: String? = nil
    ) -> EpisodeTranscriptDocument {
        var segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 5,
                text: "Welcome back to the show.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 5,
                end: 12,
                text: sponsorSegmentText,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        if let extraSegmentText {
            segments.append(OpenCastTranscriptSegment(
                id: 2,
                start: 12,
                end: 16,
                text: extraSegmentText,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ))
        }

        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 987_654_321,
            sourceFileSHA256: "source-sha",
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
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAdAnalysisTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        fileStore: EpisodeAdAnalysisFileStore,
        environment: ScriptedAdAnalysisRunEnvironment = ScriptedAdAnalysisRunEnvironment(),
        client: any EpisodeAdAnalysisClient = UnpolledAdAnalysisClient(),
        preparationGate: @escaping @Sendable () async throws -> Void = {}
    ) -> EpisodeAdAnalysisStore {
        EpisodeAdAnalysisStore(
            client: client,
            fileStore: fileStore,
            runEnvironment: environment,
            preparationGate: preparationGate
        )
    }

    /// Starts a run that holds its first send, then lets its card expire;
    /// returns the open run's id.
    private func expireRun(
        of transcript: EpisodeTranscriptDocument,
        store: EpisodeAdAnalysisStore,
        environment: ScriptedAdAnalysisRunEnvironment,
        context: ModelContext
    ) async throws -> String {
        let sent = environment.sends.count
        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil { environment.sends.count == sent + 1 })
        store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !store.hasActiveJob })
        let run = try #require(environment.latestRun)
        #expect(run.state == .expired)
        return run.id
    }

    /// Runs a two-window transcript until its first window is answered and
    /// kept, then lets the card expire; returns the open run's id.
    private func expireAfterFirstWindow(
        of transcript: EpisodeTranscriptDocument,
        store: EpisodeAdAnalysisStore,
        environment: ScriptedAdAnalysisRunEnvironment,
        context: ModelContext
    ) async throws -> String {
        environment.answerForRequest = { request in
            request.purpose == .adWindow(index: 1) ? .hold : .sponsorRead
        }
        defer { environment.answerForRequest = nil }
        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await waitUntil {
            environment.sends.count(of: .adWindow(index: 1)) == 1
                && store.analysisProgress(for: transcript.episodeID)?.completed == 1
        })
        store.cancelActiveRun(reason: .expiration)
        #expect(await waitUntil { !store.hasActiveJob })
        let run = try #require(environment.latestRun)
        #expect(run.state == .expired)
        return run.id
    }

    /// The feed's declared runtime for the episode, as the episode cache
    /// holds it.
    private func insertDeclaredRuntime(
        _ seconds: Double,
        for transcript: EpisodeTranscriptDocument,
        context: ModelContext
    ) throws {
        context.insert(EpisodeCacheRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            podcastTitle: "Example Podcast",
            title: "Example Episode",
            duration: seconds
        ))
        try context.save()
    }

    private func makeLongTranscriptDocument(episodeID: String, segmentCount: Int) -> EpisodeTranscriptDocument {
        var transcript = makeTranscriptDocument(episodeID: episodeID)
        transcript.segments = (0..<segmentCount).map { index in
            OpenCastTranscriptSegment(
                id: index,
                start: Double(index * 2),
                end: Double(index * 2 + 2),
                text: index == 1
                    ? "This episode is brought to you by Example Sponsor."
                    : "Part \(index) of the conversation continues here.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")
        transcript.audioDuration = Double(segmentCount * 2)
        return transcript
    }

    private func startAndWait(
        store: EpisodeAdAnalysisStore,
        transcript: EpisodeTranscriptDocument,
        modelContext: ModelContext
    ) async {
        store.startAnalysis(transcript: transcript, modelContext: modelContext)
        #expect(await waitUntil {
            !store.hasActiveJob
                && store.record(for: transcript.episodeID)?.state == .completed
        })
    }
}

/// One provider refusal and what the listener is told about it.
struct ProviderRefusal: Sendable, CustomTestStringConvertible {
    let answer: ScriptedAdAnswer
    let kind: EpisodeAnalysisFailureKind
    let listener: AnalysisProviderFailure
    let code: String

    var testDescription: String {
        "\(code), \(listener.rawValue)"
    }
}

/// A trial refusal and the reason the key screen gives for it.
struct TrialRefusal: Sendable, CustomTestStringConvertible {
    let answer: ScriptedAdAnswer
    let kind: EpisodeAnalysisFailureKind
    let reason: AnalysisKeyRequiredReason

    var answerListener: AnalysisProviderFailure {
        if case .failure(_, _, let listener) = answer { listener } else { .requestRejected }
    }

    var testDescription: String {
        reason.rawValue
    }
}

private final class FakeEpisodeAdAnalysisHTTPTransport: EpisodeAdAnalysisHTTPTransport, AppAttestHTTPTransport, @unchecked Sendable {
    private let statusCode: Int
    private let body: Data
    private(set) var lastRequest: URLRequest?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (body, response)
    }
}

private final class AppAttestRoutingHTTPTransport: EpisodeAdAnalysisHTTPTransport, AppAttestHTTPTransport, @unchecked Sendable {
    private var pollResponses: [ServiceResponse]
    private var challengeCount = 0
    private(set) var requestPaths: [String] = []
    private(set) var registerRequests: [CapturedAppAttestRegisterRequest] = []
    private(set) var pollEnvelopes: [CapturedAppAttestEnvelope] = []
    private(set) var pollRequestTimeouts: [TimeInterval] = []

    init(pollResponses: [ServiceResponse]) {
        self.pollResponses = pollResponses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        requestPaths.append(path)

        let response: (statusCode: Int, body: Data)
        switch path {
        case "/v1/app-attest/challenge":
            challengeCount += 1
            response = (
                200,
                Data("""
                {
                  "challenge_id": "challenge-\(challengeCount)",
                  "challenge": "challenge-value-\(challengeCount)"
                }
                """.utf8)
            )
        case "/v1/app-attest/register":
            let body = try #require(request.httpBody)
            registerRequests.append(try JSONDecoder().decode(
                CapturedAppAttestRegisterRequest.self,
                from: body
            ))
            response = (200, Data(#"{"message":"registered"}"#.utf8))
        case let path where path.hasPrefix("/v1/ad-analysis/jobs/"):
            let body = try #require(request.httpBody)
            pollRequestTimeouts.append(request.timeoutInterval)
            pollEnvelopes.append(try JSONDecoder().decode(
                CapturedAppAttestEnvelope.self,
                from: body
            ))
            response = try #require(pollResponses.isEmpty ? nil : pollResponses.removeFirst().httpResponse)
        default:
            response = (404, Data(#"{"error":"not_found"}"#.utf8))
        }

        let urlResponse = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (response.body, urlResponse)
    }
}

private enum ServiceResponse {
    case running(jobID: String)
    case error(statusCode: Int, code: String)

    var httpResponse: (statusCode: Int, body: Data) {
        switch self {
        case .running(let jobID):
            return (
                202,
                Data(#"{"job_id":"\#(jobID)","state":"running","poll_after_seconds":10}"#.utf8)
            )
        case .error(let statusCode, let code):
            return (statusCode, Data(#"{"error":"\#(code)"}"#.utf8))
        }
    }
}

private struct CapturedAppAttestRegisterRequest: Decodable {
    let installID: String
    let keyID: String
    let challengeID: String
    let challenge: String
    let attestationObject: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case challengeID = "challenge_id"
        case challenge
        case attestationObject = "attestation_object"
    }
}

private struct CapturedAppAttestEnvelope: Decodable {
    let installID: String
    let keyID: String
    let payload: String
    let assertion: String?

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case payload
        case assertion
    }
}

private final class FakeAppAttestService: AppAttestServiceProtocol, @unchecked Sendable {
    let isSupported: Bool
    private let keyIDs: [String]
    private var nextKeyIndex = 0
    private(set) var generatedKeys: [String] = []
    private(set) var attestationKeyIDs: [String] = []
    private(set) var attestationClientDataHashes: [String] = []
    private(set) var assertionKeyIDs: [String] = []
    private(set) var assertionClientDataHashes: [String] = []

    init(isSupported: Bool, keyIDs: [String] = ["fake-key"]) {
        self.isSupported = isSupported
        self.keyIDs = keyIDs
    }

    func generateKey() async throws -> String {
        let keyID = keyIDs[min(nextKeyIndex, keyIDs.count - 1)]
        nextKeyIndex += 1
        generatedKeys.append(keyID)
        return keyID
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationKeyIDs.append(keyID)
        attestationClientDataHashes.append(AppAttestRequestBinding.hexString(clientDataHash))
        return Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionKeyIDs.append(keyID)
        assertionClientDataHashes.append(AppAttestRequestBinding.hexString(clientDataHash))
        return Data("assertion-\(keyID)".utf8)
    }
}

/// Whether the usage store's saves fail, flipped by a test.
private final class UsageSaveSwitch {
    var fails = true
}
