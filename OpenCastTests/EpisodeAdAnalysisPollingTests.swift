import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad analysis polling")
struct EpisodeAdAnalysisPollingTests {
    @Test("Accepted job polls to completion and writes its document")
    func acceptedJobPollsToCompletionAndWritesDocument() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 0)],
            pollSteps: [.running(pollAfter: 0), .completed]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-complete")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let counts = await client.counts()
        #expect(counts.submit == 1)
        #expect(counts.poll == 2)
        #expect(record.jobAcceptedAt == nil)
        #expect(document.requestID == "polled-response")
        #expect(document.transcriptFingerprint == record.transcriptFingerprint)
    }

    @Test("Transient poll failure resubmits once and completes")
    func transientPollFailureResubmitsOnceAndCompletes() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 0), .completed],
            pollSteps: [.http(statusCode: 503, code: "job_failed_transient")]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-resubmit")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let counts = await client.counts()
        #expect(counts.submit == 2)
        #expect(counts.poll == 1)
    }

    @Test("Second transient poll failure becomes retryable generic failure")
    func secondTransientPollFailureBecomesGenericFailure() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 0), .accepted(pollAfter: 0)],
            pollSteps: [
                .http(statusCode: 503, code: "job_failed_transient"),
                .http(statusCode: 404, code: "job_not_found")
            ]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-second-transient")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let counts = await client.counts()
        #expect(counts.submit == 2)
        #expect(counts.poll == 2)
        #expect(record.failureKind == .generic)
        #expect(record.jobAcceptedAt == nil)
    }

    @Test("Poll cap rejection keeps typed cap failure")
    func pollCapRejectionKeepsTypedCapFailure() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 0)],
            pollSteps: [.http(statusCode: 429, code: "daily_request_cap_exceeded")]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-cap")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(store.record(for: transcript.episodeID)?.failureKind == .capExceeded)
    }

    @Test("Lost submit response recovers by polling the fingerprint job")
    func lostSubmitResponseRecoversByPollingTheFingerprintJob() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        // The observed production failure: the worker finished the analysis
        // but the device lost the connection while receiving the response.
        // The job ID is the transcript fingerprint, so the store needs no
        // second submit — it polls straight for the result.
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.urlError(.networkConnectionLost)],
            pollSteps: [.completed]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-lost-submit")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let counts = await client.counts()
        let identifiers = await client.recordedIdentifiers()
        #expect(counts.submit == 1)
        #expect(counts.poll == 1)
        #expect(identifiers.polledJobIDs == [record.transcriptFingerprint])
        #expect(identifiers.fingerprint == record.transcriptFingerprint)
    }

    @Test("Lost submit that never landed resubmits through the poll loop")
    func lostSubmitThatNeverLandedResubmitsThroughThePollLoop() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.urlError(.networkConnectionLost), .accepted(pollAfter: 0)],
            pollSteps: [.http(statusCode: 404, code: "job_not_found"), .completed]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-lost-submit-404")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let counts = await client.counts()
        #expect(counts.submit == 2)
        #expect(counts.poll == 2)
    }

    @Test("Polling deadline records analysis timed out")
    func pollingDeadlineRecordsAnalysisTimedOut() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 120)],
            pollSteps: []
        )
        let store = makeStore(
            client: client,
            directory: directory,
            pollingTimeout: .zero
        )
        let transcript = makeTranscript(episodeID: "poll-timeout")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let counts = await client.counts()
        #expect(counts.poll == 0)
        #expect(record.errorMessage == EpisodeAdAnalysisError.analysisTimedOut.localizedDescription)
        #expect(record.failureKind == .generic)
    }

    @Test("Three consecutive URL errors are tolerated")
    func threeConsecutiveURLErrorsAreTolerated() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 0)],
            pollSteps: [
                .urlError(.networkConnectionLost),
                .urlError(.timedOut),
                .urlError(.notConnectedToInternet),
                .completed
            ]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-url-errors")

        store.startAnalysis(transcript: transcript, modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect((await client.counts()).poll == 4)
    }

    @Test("Cancellation during quiet polling leaves a resumable record")
    func cancellationDuringPollingLeavesResumableRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [.accepted(pollAfter: 0)],
            pollSteps: [.running(pollAfter: 0), .suspend]
        )
        let store = makeStore(client: client, directory: directory)
        let transcript = makeTranscript(episodeID: "poll-cancel")

        store.startAnalysis(transcript: transcript, modelContext: context)
        #expect(await client.waitForPollCount(2))
        let acceptedRecord = try #require(store.record(for: transcript.episodeID))
        let acceptedUpdatedAt = acceptedRecord.updatedAt
        #expect(acceptedRecord.state == .running)
        #expect(acceptedRecord.jobAcceptedAt != nil)
        #expect(acceptedRecord.updatedAt == acceptedUpdatedAt)

        store.cancelActiveJob()

        #expect(await waitUntil(store) { !store.hasActiveJob })
        let cancelledRecord = try #require(store.record(for: transcript.episodeID))
        #expect(cancelledRecord.state == .running)
        #expect(cancelledRecord.jobAcceptedAt != nil)
        #expect(cancelledRecord.updatedAt == acceptedUpdatedAt)
    }

    @Test("Load resumes a recent accepted record from persisted fields")
    func loadResumesRecentAcceptedRecordFromPersistedFields() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let record = makeRunningRecord(
            episodeID: "resume-complete",
            fingerprint: "resume-fingerprint",
            relativePath: "AdAnalysis/resume-complete/result.json",
            jobAcceptedAt: .now
        )
        context.insert(record)
        try context.save()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [],
            pollSteps: [.completed]
        )
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: fileStore,
            resumeInitialPollAfter: 0,
            pollingSleep: { _ in }
        )

        store.load(modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: record.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: record.episodeID))
        let counts = await client.counts()
        #expect(counts.submit == 0)
        #expect(counts.poll == 1)
        #expect(document.episodeID == record.episodeID)
        #expect(document.podcastID == record.podcastID)
        #expect(document.transcriptFingerprint == "resume-fingerprint")
        #expect(document.transcriptUpdatedAt == record.transcriptUpdatedAt)
        #expect(document.transcriptSegmentCount == record.transcriptSegmentCount)
    }

    @Test("Reconcile fails queued, unaccepted, and expired records")
    func reconcileFailsNonresumableRecords() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let unaccepted = makeRunningRecord(
            episodeID: "resume-unaccepted",
            fingerprint: "unaccepted-fingerprint",
            relativePath: "AdAnalysis/unaccepted/result.json",
            jobAcceptedAt: nil
        )
        let queued = makeRunningRecord(
            episodeID: "resume-queued",
            fingerprint: "queued-fingerprint",
            relativePath: "AdAnalysis/queued/result.json",
            jobAcceptedAt: .now,
            state: .queued
        )
        let expired = makeRunningRecord(
            episodeID: "resume-expired",
            fingerprint: "expired-fingerprint",
            relativePath: "AdAnalysis/expired/result.json",
            jobAcceptedAt: Date.now.addingTimeInterval(-3_601)
        )
        context.insert(unaccepted)
        context.insert(queued)
        context.insert(expired)
        try context.save()
        let store = makeStore(
            client: PollingEpisodeAdAnalysisClient(submitSteps: [], pollSteps: []),
            directory: directory
        )

        store.load(modelContext: context)

        for episodeID in [unaccepted.episodeID, queued.episodeID, expired.episodeID] {
            let reconciled = try #require(store.record(for: episodeID))
            #expect(reconciled.state == .failed)
            #expect(reconciled.failureKind == .generic)
            #expect(reconciled.jobAcceptedAt == nil)
            #expect(reconciled.errorMessage == "Promo/ad analysis was interrupted.")
        }
        #expect(!store.hasActiveJob)
    }

    @Test("Resume job not found becomes retryable generic failure without submit")
    func resumeJobNotFoundBecomesGenericFailureWithoutSubmit() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let record = makeRunningRecord(
            episodeID: "resume-not-found",
            fingerprint: "not-found-fingerprint",
            relativePath: "AdAnalysis/not-found/result.json",
            jobAcceptedAt: .now
        )
        context.insert(record)
        try context.save()
        let client = PollingEpisodeAdAnalysisClient(
            submitSteps: [],
            pollSteps: [.http(statusCode: 404, code: "job_not_found")]
        )
        let store = EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            resumeInitialPollAfter: 0,
            pollingSleep: { _ in }
        )

        store.load(modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: record.episodeID)?.state == .failed
        })
        let failedRecord = try #require(store.record(for: record.episodeID))
        let counts = await client.counts()
        #expect(counts.submit == 0)
        #expect(counts.poll == 1)
        #expect(failedRecord.failureKind == .generic)
        #expect(failedRecord.jobAcceptedAt == nil)
    }

    private func makeStore(
        client: some EpisodeAdAnalysisClient,
        directory: URL,
        pollingTimeout: Duration = .seconds(30)
    ) -> EpisodeAdAnalysisStore {
        EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            pollingTimeout: pollingTimeout,
            resumeInitialPollAfter: 0,
            pollingSleep: { _ in }
        )
    }

    @Test("record(for:) matches a linear scan after load")
    func recordLookupMatchesLinearScan() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        for index in 1...3 {
            context.insert(makeRunningRecord(
                episodeID: "index-eq-\(index)",
                fingerprint: "index-eq-fp-\(index)",
                relativePath: "AdAnalysis/index-eq-\(index)/result.json",
                jobAcceptedAt: nil,
                state: .failed
            ))
        }
        try context.save()
        let store = makeStore(
            client: PollingEpisodeAdAnalysisClient(submitSteps: [], pollSteps: []),
            directory: directory
        )

        store.load(modelContext: context)

        for episodeID in ["index-eq-1", "index-eq-2", "index-eq-3", "index-eq-missing"] {
            #expect(store.record(for: episodeID) === store.records.first { $0.episodeID == episodeID })
        }
    }

    private func makeRunningRecord(
        episodeID: String,
        fingerprint: String,
        relativePath: String,
        jobAcceptedAt: Date?,
        state: EpisodeAdAnalysisState = .running
    ) -> EpisodeAdAnalysisRecord {
        EpisodeAdAnalysisRecord(
            episodeID: episodeID,
            podcastID: "https://example.com/resume.xml",
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            transcriptSegmentCount: 2_100,
            transcriptState: .completed,
            state: state,
            analysisRelativePath: relativePath,
            jobAcceptedAt: jobAcceptedAt
        )
    }

    private func makeTranscript(episodeID: String) -> EpisodeTranscriptDocument {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let segments = [
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
                text: "This episode is brought to you by Example Sponsor.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 100,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: 12,
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
            .appending(path: "OpenCastAdPollingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Signal-driven: wakes on every store change instead of a fixed poll
    /// budget, so load cannot outrun the wait. The backstop only trips on a
    /// real regression.
    private func waitUntil(
        _ store: EpisodeAdAnalysisStore,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else {
                return false
            }
            let sequence = store.changeSequence
            let waitTask = Task { @MainActor in
                try? await store.waitForChange(after: sequence)
            }
            let backstop = Task {
                try? await Task.sleep(until: deadline, clock: clock)
                waitTask.cancel()
            }
            await waitTask.value
            backstop.cancel()
        }
        return true
    }
}

private enum PollingSubmitStep: Sendable {
    case accepted(pollAfter: TimeInterval)
    case completed
    case urlError(URLError.Code)
}

private enum PollingPollStep: Sendable {
    case running(pollAfter: TimeInterval)
    case completed
    case http(statusCode: Int, code: String)
    case urlError(URLError.Code)
    case suspend
}

private actor PollingEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    private var submitSteps: [PollingSubmitStep]
    private var pollSteps: [PollingPollStep]
    private var submitCount = 0
    private var pollCount = 0
    private var submittedFingerprint: String?
    private var polledJobIDs: [String] = []
    private var pollWaiters: [UUID: (threshold: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    init(submitSteps: [PollingSubmitStep], pollSteps: [PollingPollStep]) {
        self.submitSteps = submitSteps
        self.pollSteps = pollSteps
    }

    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        submitCount += 1
        submittedFingerprint = request.transcript.fingerprint
        guard !submitSteps.isEmpty else {
            throw EpisodeAdAnalysisHTTPError(statusCode: 500, code: "unexpected_submit", detail: nil)
        }

        switch submitSteps.removeFirst() {
        case .accepted(let pollAfter):
            return .accepted(jobID: request.transcript.fingerprint, pollAfter: pollAfter)
        case .completed:
            return .completed(Self.response(requestID: request.requestID))
        case .urlError(let code):
            throw URLError(code)
        }
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        pollCount += 1
        resumeSatisfiedPollWaiters()
        polledJobIDs.append(id)
        guard !pollSteps.isEmpty else {
            throw EpisodeAdAnalysisHTTPError(statusCode: 500, code: "unexpected_poll", detail: nil)
        }

        switch pollSteps.removeFirst() {
        case .running(let pollAfter):
            return .running(pollAfter: pollAfter)
        case .completed:
            return .completed(Self.response(requestID: "polled-response"))
        case .http(let statusCode, let code):
            throw EpisodeAdAnalysisHTTPError(statusCode: statusCode, code: code, detail: nil)
        case .urlError(let code):
            throw URLError(code)
        case .suspend:
            // Parked: cancellation of the polling task is the only exit.
            while true {
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func counts() -> (submit: Int, poll: Int) {
        (submitCount, pollCount)
    }

    func recordedIdentifiers() -> (fingerprint: String?, polledJobIDs: [String]) {
        (submittedFingerprint, polledJobIDs)
    }

    /// Signal-driven: each `pollJob` arrival resumes satisfied waiters, so
    /// there is no polling budget to race. The backstop only trips on a real
    /// regression.
    func waitForPollCount(_ expectedCount: Int) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pollCountReached(expectedCount) }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
        return pollCount >= expectedCount
    }

    private func pollCountReached(_ threshold: Int) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pollCount >= threshold || Task.isCancelled {
                    continuation.resume()
                    return
                }
                pollWaiters[waiterID] = (threshold, continuation)
            }
        } onCancel: {
            Task { await self.cancelPollWaiter(waiterID) }
        }
    }

    private func cancelPollWaiter(_ waiterID: UUID) {
        pollWaiters.removeValue(forKey: waiterID)?.continuation.resume()
    }

    private func resumeSatisfiedPollWaiters() {
        let ready = pollWaiters.filter { $0.value.threshold <= pollCount }
        for (waiterID, waiter) in ready {
            pollWaiters.removeValue(forKey: waiterID)
            waiter.continuation.resume()
        }
    }

    private static func response(requestID: String) -> EpisodeAdAnalysisAPIResponse {
        EpisodeAdAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [
                EpisodeAdAnalysisAPIAdSpan(
                    kind: .hostReadAd,
                    label: "Example Sponsor",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 5,
                    endTime: 12,
                    confidence: 0.96,
                    evidenceQuote: "brought to you"
                )
            ],
            warnings: [],
            usage: nil
        )
    }
}
