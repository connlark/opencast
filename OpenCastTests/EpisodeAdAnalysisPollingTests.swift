import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// A job an earlier build started on the analysis service is polled to
/// completion at launch, never resubmitted; no device run starts for it.
@MainActor
@Suite("Episode ad analysis polling")
struct EpisodeAdAnalysisPollingTests {
    @Test("A job accepted before the update completes through the poller with no resubmit and no device run")
    func acceptedJobCompletesThroughPollerWithoutDeviceRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let transcript = makeTranscript(episodeID: "drain-complete")
        try writeTranscript(transcript, directory: directory, context: context)
        let handle = try insertAcceptedJob(for: transcript, fileStore: fileStore, context: context, revision: "20261020b")
        let client = PollingEpisodeAdAnalysisClient(pollSteps: [.running(pollAfter: 0), .completed])
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(client: client, directory: directory, environment: environment)

        store.load(modelContext: context)

        #expect(await waitUntil(store) {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        #expect(await client.polledJobIDs() == [handle, handle])
        #expect(record.jobAcceptedAt == nil)
        #expect(document.requestID == "polled-response")
        #expect(document.transcriptFingerprint == record.transcriptFingerprint)
        #expect(store.isCurrentAnalysisDocument(document, for: transcript))
        #expect(environment.resolvedRunIDs.isEmpty)
        #expect(environment.sends.count == 0)
        #expect(environment.runs.records(limit: 10).isEmpty)
    }

    @Test("A lost job fails as interrupted and is never resubmitted")
    func lostJobIsInterruptedWithoutResubmit() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let transcript = makeTranscript(episodeID: "drain-lost")
        try writeTranscript(transcript, directory: directory, context: context)
        _ = try insertAcceptedJob(for: transcript, fileStore: fileStore, context: context)
        let client = PollingEpisodeAdAnalysisClient(pollSteps: [.http(statusCode: 503, code: "job_failed_transient")])
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(client: client, directory: directory, environment: environment)

        store.load(modelContext: context)

        #expect(await waitUntil(store) {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(await client.pollCount() == 1)
        #expect(record.failureKind == .interrupted)
        #expect(record.jobAcceptedAt == nil)
        #expect(environment.resolvedRunIDs.isEmpty)
        #expect(environment.sends.count == 0)
    }

    @Test("A job_unavailable poll keeps the accepted handle and completes")
    func jobUnavailablePollKeepsHandleAndCompletes() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-job-unavailable",
            revision: "20261020b",
            pollSteps: [.http(statusCode: 503, code: "job_unavailable"), .completed]
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            fixture.store.record(for: fixture.episodeID)?.state == .completed
        })
        #expect(await fixture.client.polledJobIDs() == [fixture.handle, fixture.handle])
    }

    @Test("Untyped 5xx polls retry the same handle until the job completes")
    func untypedServerErrorPollsRetrySameHandle() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-untyped-5xx",
            pollSteps: [
                .http(statusCode: 500, code: "http_500"),
                .running(pollAfter: 0),
                .http(statusCode: 502, code: "http_502"),
                .completed
            ]
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            fixture.store.record(for: fixture.episodeID)?.state == .completed
        })
        #expect(await fixture.client.pollCount() == 4)
    }

    @Test("A job object that stays unavailable past the ladder fails as service unavailable")
    func persistentJobUnavailableFailsAsServiceUnavailable() async throws {
        // Eight retries, so the ninth unavailable read is the one that fails.
        let fixture = try makeDrainFixture(
            episodeID: "drain-job-unavailable-exhausted",
            pollSteps: Array(repeating: .http(statusCode: 503, code: "job_unavailable"), count: 9)
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            !fixture.store.hasActiveJob && fixture.store.record(for: fixture.episodeID)?.state == .failed
        })
        let record = try #require(fixture.store.record(for: fixture.episodeID))
        #expect(await fixture.client.pollCount() == 9)
        #expect(record.failureKind == .serviceUnavailable)
        #expect(record.errorMessage == "Promo/ad analysis failed (job_unavailable).")
    }

    @Test("A stored usage_limiter_error stays terminal")
    func storedUsageLimiterErrorIsTerminal() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-usage-limiter-error",
            pollSteps: [.http(statusCode: 503, code: "usage_limiter_error", failure: .transientTransport)]
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            !fixture.store.hasActiveJob && fixture.store.record(for: fixture.episodeID)?.state == .failed
        })
        #expect(await fixture.client.pollCount() == 1)
        #expect(fixture.store.record(for: fixture.episodeID)?.failureKind == .serviceUnavailable)
    }

    @Test("A poll cap rejection keeps the typed cap failure")
    func pollCapRejectionKeepsTypedCapFailure() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-cap",
            pollSteps: [.http(statusCode: 429, code: "daily_request_cap_exceeded")]
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            fixture.store.record(for: fixture.episodeID)?.state == .failed
        })
        #expect(fixture.store.record(for: fixture.episodeID)?.failureKind == .capExceeded)
    }

    @Test("A model timeout without an output document remains a Retry error after reopening the store")
    func modelTimeoutRemainsRetryableAfterReopeningStore() async throws {
        let directory = try makeTemporaryDirectory()
        let configuration = ModelConfiguration(
            schema: OpenCastModelContainerFactory.localSchema,
            url: directory.appending(path: "LocalDeviceData.store"),
            cloudKitDatabase: .none
        )
        let transcript = makeTranscript(episodeID: "drain-timeout-relaunch")
        let files = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let client = PollingEpisodeAdAnalysisClient(
            pollSteps: [.http(statusCode: 503, code: "gemini_timeout", failure: .transientTransport)]
        )

        do {
            let container = try ModelContainer(
                for: OpenCastModelContainerFactory.localSchema,
                configurations: [configuration]
            )
            let context = ModelContext(container)
            try writeTranscript(transcript, directory: directory, context: context)
            _ = try insertAcceptedJob(for: transcript, fileStore: files, context: context)
            let store = makeStore(client: client, directory: directory)
            store.load(modelContext: context)
            #expect(await waitUntil(store) {
                !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
            })
            let record = try #require(store.record(for: transcript.episodeID))
            #expect(!files.documentExists(relativePath: record.analysisRelativePath))
            guard case .failed(_, isStale: false) = store.jobState(for: transcript) else {
                Issue.record("A timeout for the current transcript must be a current failure without an output file.")
                return
            }
        }

        let reopenedContainer = try ModelContainer(
            for: OpenCastModelContainerFactory.localSchema,
            configurations: [configuration]
        )
        let reloadedStore = makeStore(client: client, directory: directory)
        reloadedStore.load(modelContext: ModelContext(reopenedContainer))
        let detail = await reloadedStore.episodeDetailState(
            for: transcript,
            transcriptState: .completed,
            analysisDocument: nil
        )
        guard case .failed(let record, isStale: false) = detail.jobState else {
            Issue.record("Reopening must preserve the current timeout failure without an output file.")
            return
        }
        #expect(record.errorMessage == "Promo/ad analysis failed (gemini_timeout).")
        #expect(record.failureKind == .timedOut)
        #expect(record.jobAcceptedAt == nil)
        #expect(!detail.hasCurrentCompletedAnalysis)
        #expect(!reloadedStore.hasActiveJob)
        #expect(await client.pollCount() == 1)

        let pipeline = try #require(EpisodePipelineState.make(
            episodeID: transcript.episodeID,
            queueStatus: .notQueued,
            queueSnapshot: AdFreePassQueueSnapshot(),
            downloadRecord: nil,
            transcription: .unavailable,
            analysis: detail.jobState
        ))
        #expect(pipeline.title == EpisodePipelineState.analysisFailedTitle)
        #expect(pipeline.action == .retryAnalysis)
        #expect(pipeline.steps == [EpisodePipelineStep(
            kind: .detectAds,
            status: .failed(message: EpisodePipelineState.analysisFailedMessage(for: .timedOut))
        )])
    }

    @Test("A failed analysis without output stays stale when the transcript changes")
    func failedAnalysisWithoutOutputStaysStaleForChangedTranscript() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-timeout-changed-transcript",
            pollSteps: [.http(statusCode: 503, code: "gemini_timeout", failure: .transientTransport)]
        )
        fixture.store.load(modelContext: fixture.context)
        #expect(await waitUntil(fixture.store) {
            !fixture.store.hasActiveJob && fixture.store.record(for: fixture.episodeID)?.state == .failed
        })

        var transcript = fixture.transcript
        transcript.segments[0].text = "A different episode opening."
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")
        let reloadedStore = makeStore(client: fixture.client, directory: fixture.directory)
        reloadedStore.load(modelContext: fixture.context)
        let detail = await reloadedStore.episodeDetailState(
            for: transcript,
            transcriptState: .completed,
            analysisDocument: nil
        )
        guard case .failed(_, isStale: true) = detail.jobState else {
            Issue.record("A failure for different transcript content must remain stale.")
            return
        }
        #expect(EpisodePipelineState.make(
            episodeID: transcript.episodeID,
            queueStatus: .notQueued,
            queueSnapshot: AdFreePassQueueSnapshot(),
            downloadRecord: nil,
            transcription: .unavailable,
            analysis: detail.jobState
        ) == nil)
    }

    @Test("Polling deadline records analysis timed out")
    func pollingDeadlineRecordsAnalysisTimedOut() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-deadline",
            pollSteps: [],
            pollingTimeout: .zero
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            fixture.store.record(for: fixture.episodeID)?.state == .failed
        })
        let record = try #require(fixture.store.record(for: fixture.episodeID))
        #expect(await fixture.client.pollCount() == 0)
        #expect(record.errorMessage == EpisodeAdAnalysisError.analysisTimedOut.localizedDescription)
        #expect(record.failureKind == .timedOut)
    }

    @Test("Three consecutive URL errors are tolerated")
    func threeConsecutiveURLErrorsAreTolerated() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-url-errors",
            pollSteps: [
                .urlError(.networkConnectionLost),
                .urlError(.timedOut),
                .urlError(.notConnectedToInternet),
                .completed
            ]
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            fixture.store.record(for: fixture.episodeID)?.state == .completed
        })
        #expect(await fixture.client.pollCount() == 4)
    }

    @Test("Cancelling quiet polling leaves the accepted record for the next launch")
    func cancellationDuringPollingLeavesResumableRecord() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-cancel",
            pollSteps: [.running(pollAfter: 0), .suspend]
        )

        fixture.store.load(modelContext: fixture.context)
        #expect(await fixture.client.waitForPollCount(2))
        let acceptedRecord = try #require(fixture.store.record(for: fixture.episodeID))
        let acceptedUpdatedAt = acceptedRecord.updatedAt
        #expect(acceptedRecord.state == .running)
        #expect(acceptedRecord.jobAcceptedAt != nil)

        fixture.store.cancelActiveRun(reason: .listener)

        #expect(await waitUntil(fixture.store) { !fixture.store.hasActiveJob })
        let cancelledRecord = try #require(fixture.store.record(for: fixture.episodeID))
        #expect(cancelledRecord.state == .running)
        #expect(cancelledRecord.jobAcceptedAt != nil)
        #expect(cancelledRecord.updatedAt == acceptedUpdatedAt)
    }

    @Test("An unknown span kind from a polled job fails cleanly, never a trusted skip")
    func unknownSpanKindFailsCleanlyInsteadOfTrustedSkip() async throws {
        let fixture = try makeDrainFixture(
            episodeID: "drain-unknown-kind",
            pollSteps: [.completedWithKind(.unknown)]
        )

        fixture.store.load(modelContext: fixture.context)

        #expect(await waitUntil(fixture.store) {
            fixture.store.record(for: fixture.episodeID)?.state == .failed
        })
        let record = try #require(fixture.store.record(for: fixture.episodeID))
        #expect(record.failureKind == .generic)
        #expect(record.errorMessage == EpisodeAdAnalysisError.unrecognizedSpanKind.localizedDescription)
        #expect(fixture.store.document(for: fixture.episodeID) == nil)
    }

    @Test("Load resumes a recent accepted record from persisted fields under its legacy handle")
    func loadResumesRecentAcceptedRecordFromPersistedFields() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let record = makeRunningRecord(
            episodeID: "resume-complete",
            fingerprint: "resume-fingerprint",
            relativePath: "AdAnalysis/resume-complete/result.json",
            jobAcceptedAt: .now
        )
        context.insert(record)
        try context.save()
        let client = PollingEpisodeAdAnalysisClient(pollSteps: [.completed])
        let store = makeStore(client: client, directory: directory)

        store.load(modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: record.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: record.episodeID))
        #expect(await client.polledJobIDs() == ["resume-fingerprint"])
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
        let environment = ScriptedAdAnalysisRunEnvironment()
        let store = makeStore(
            client: PollingEpisodeAdAnalysisClient(pollSteps: []),
            directory: directory,
            environment: environment
        )

        store.load(modelContext: context)

        for episodeID in [unaccepted.episodeID, queued.episodeID, expired.episodeID] {
            let reconciled = try #require(store.record(for: episodeID))
            #expect(reconciled.state == .failed)
            #expect(reconciled.failureKind == .interrupted)
            #expect(reconciled.jobAcceptedAt == nil)
            #expect(reconciled.errorMessage == "Promo/ad analysis was interrupted.")
        }
        #expect(!store.hasActiveJob)
        #expect(environment.resolvedRunIDs.isEmpty)
    }

    @Test("One run resumes per launch: a job that comes first drains, and the open device run fails as interrupted")
    func oneRunResumesPerLaunch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let environment = ScriptedAdAnalysisRunEnvironment()
        let job = makeTranscript(episodeID: "launch-job")
        let device = makeTranscript(episodeID: "launch-device")
        try writeTranscript(job, directory: directory, context: context)
        try writeTranscript(device, directory: directory, context: context)
        _ = try insertAcceptedJob(for: job, fileStore: fileStore, context: context)
        let fingerprint = fileStore.transcriptFingerprint(for: device)
        let deviceRecord = makeRunningRecord(
            episodeID: device.episodeID,
            fingerprint: fingerprint,
            relativePath: fileStore.relativePath(episodeID: device.episodeID, transcriptFingerprint: fingerprint),
            jobAcceptedAt: nil
        )
        // Records reconcile newest first; the older device record finds the
        // one resume slot taken.
        deviceRecord.updatedAt = Date.now.addingTimeInterval(-60)
        context.insert(deviceRecord)
        try context.save()
        let policy = try #require(environment.snapshot.adDetection(provider: .google))
        try environment.runs.begin(AnalysisRunRecord(
            feature: .adDetection,
            episodeID: device.episodeID,
            podcastID: device.podcastID,
            transcriptFingerprint: fingerprint,
            resolution: AnalysisRouteResolution(
                feature: .adDetection,
                route: .direct(provider: .google),
                policy: .adDetection(policy),
                key: nil,
                resumingRunID: nil,
                trialExchange: nil
            ),
            policy: .adDetection(policy)
        ))
        let client = PollingEpisodeAdAnalysisClient(pollSteps: [.completed])
        let store = makeStore(client: client, directory: directory, environment: environment)

        store.load(modelContext: context)

        #expect(store.record(for: device.episodeID)?.state == .failed)
        #expect(store.record(for: device.episodeID)?.failureKind == .interrupted)
        #expect(await waitUntil(store) {
            !store.hasActiveJob && store.record(for: job.episodeID)?.state == .completed
        })
        #expect(environment.resolvedRunIDs.isEmpty)
        #expect(environment.sends.count == 0)
    }

    @Test("Resume job not found becomes an interrupted failure without a submit")
    func resumeJobNotFoundBecomesInterruptedFailureWithoutSubmit() async throws {
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
        let client = PollingEpisodeAdAnalysisClient(pollSteps: [.http(statusCode: 404, code: "job_not_found")])
        let store = makeStore(client: client, directory: directory)

        store.load(modelContext: context)

        #expect(await waitUntil(store) {
            store.record(for: record.episodeID)?.state == .failed
        })
        let failedRecord = try #require(store.record(for: record.episodeID))
        #expect(await client.pollCount() == 1)
        #expect(failedRecord.failureKind == .interrupted)
        #expect(failedRecord.jobAcceptedAt == nil)
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
            client: PollingEpisodeAdAnalysisClient(pollSteps: []),
            directory: directory
        )

        store.load(modelContext: context)

        for episodeID in ["index-eq-1", "index-eq-2", "index-eq-3", "index-eq-missing"] {
            #expect(store.record(for: episodeID) === store.records.first { $0.episodeID == episodeID })
        }
    }

    // MARK: - Fixtures

    private struct DrainFixture {
        let context: ModelContext
        let directory: URL
        let transcript: EpisodeTranscriptDocument
        let handle: String
        let client: PollingEpisodeAdAnalysisClient
        let store: EpisodeAdAnalysisStore

        var episodeID: String {
            transcript.episodeID
        }
    }

    /// A transcript on disk and its running record with a job the service
    /// accepted before the update, ready for `load`.
    private func makeDrainFixture(
        episodeID: String,
        revision: String? = nil,
        pollSteps: [PollingPollStep],
        pollingTimeout: Duration = .seconds(30)
    ) throws -> DrainFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let transcript = makeTranscript(episodeID: episodeID)
        try writeTranscript(transcript, directory: directory, context: context)
        let handle = try insertAcceptedJob(
            for: transcript,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            context: context,
            revision: revision
        )
        let client = PollingEpisodeAdAnalysisClient(pollSteps: pollSteps)
        let store = makeStore(client: client, directory: directory, pollingTimeout: pollingTimeout)
        return DrainFixture(
            context: context,
            directory: directory,
            transcript: transcript,
            handle: handle,
            client: client,
            store: store
        )
    }

    private func makeStore(
        client: some EpisodeAdAnalysisClient,
        directory: URL,
        environment: ScriptedAdAnalysisRunEnvironment = ScriptedAdAnalysisRunEnvironment(),
        pollingTimeout: Duration = .seconds(30)
    ) -> EpisodeAdAnalysisStore {
        EpisodeAdAnalysisStore(
            client: client,
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
            runEnvironment: environment,
            pollingTimeout: pollingTimeout,
            resumeInitialPollAfter: 0,
            pollingSleep: { _ in }
        )
    }

    /// The running record and run state an earlier build left for a job the
    /// service accepted; returns the job's handle (`a3.<revision>.<fp>`, or
    /// the bare fingerprint without a revision).
    private func insertAcceptedJob(
        for transcript: EpisodeTranscriptDocument,
        fileStore: EpisodeAdAnalysisFileStore,
        context: ModelContext,
        revision: String? = nil
    ) throws -> String {
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcript.segments)
        let fingerprint = fileStore.transcriptFingerprint(for: transcript, segments: segments)
        let record = EpisodeAdAnalysisRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: segments.count,
            transcriptState: .completed,
            state: .running,
            analysisRelativePath: fileStore.relativePath(episodeID: transcript.episodeID, transcriptFingerprint: fingerprint),
            jobAcceptedAt: .now
        )
        context.insert(record)
        try context.save()
        let handle = revision.map { "a3.\($0).\(fingerprint)" } ?? fingerprint
        try fileStore.writeRunState(.init(transcriptFingerprint: fingerprint, jobID: handle), episodeID: transcript.episodeID)
        return handle
    }

    private func writeTranscript(
        _ document: EpisodeTranscriptDocument,
        directory: URL,
        context: ModelContext
    ) throws {
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: document.episodeID, fingerprint: fingerprint)
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            sourceAudioURL: document.sourceAudioURL,
            sourceFileByteCount: document.sourceFileByteCount,
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256,
            languageCode: document.languageCode,
            state: .completed,
            audioDuration: document.audioDuration,
            completedDuration: document.audioDuration,
            checkpointCount: document.checkpoints.count,
            transcriptRelativePath: relativePath,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        ))
        try context.save()
    }

    private func makeRunningRecord(
        episodeID: String,
        fingerprint: String,
        relativePath: String,
        jobAcceptedAt: Date?,
        state: EpisodeAnalysisRecordState = .running
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
        let deadline = clock.now.advanced(by: .seconds(60))
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

private enum PollingPollStep: Sendable {
    case running(pollAfter: TimeInterval)
    case completed
    case completedWithKind(EpisodeAdAnalysisSpanKind)
    /// `failure` mirrors the typed body the worker attaches to the codes it
    /// classifies (`Server/AdAnalysisWorker/src/failure.rs`); nil is an
    /// untyped body, like the platform's plain-text 500.
    case http(statusCode: Int, code: String, failure: OpenCastAdAnalysisFailure? = nil)
    case urlError(URLError.Code)
    case suspend
}

private extension OpenCastAdAnalysisFailure {
    static let transientTransport = OpenCastAdAnalysisFailure(
        category: .transientTransport,
        retryDisposition: .boundedRetry
    )
}

private actor PollingEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    private var pollSteps: [PollingPollStep]
    private var polls: [String] = []
    private var pollWaiters: [UUID: (threshold: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    init(pollSteps: [PollingPollStep]) {
        self.pollSteps = pollSteps
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        polls.append(id)
        resumeSatisfiedPollWaiters()
        guard !pollSteps.isEmpty else {
            throw EpisodeAdAnalysisHTTPError(statusCode: 500, code: "unexpected_poll", detail: nil)
        }

        switch pollSteps.removeFirst() {
        case .running(let pollAfter):
            return .running(pollAfter: pollAfter)
        case .completed:
            return .completed(Self.response(kind: .hostReadAd))
        case .completedWithKind(let kind):
            return .completed(Self.response(kind: kind))
        case .http(let statusCode, let code, let failure):
            throw EpisodeAdAnalysisHTTPError(statusCode: statusCode, code: code, detail: nil, failure: failure)
        case .urlError(let code):
            throw URLError(code)
        case .suspend:
            // Parked: cancellation of the polling task is the only exit.
            while true {
                try await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func pollCount() -> Int {
        polls.count
    }

    func polledJobIDs() -> [String] {
        polls
    }

    /// Signal-driven: each `pollJob` arrival resumes satisfied waiters, so
    /// there is no polling budget to race. The backstop only trips on a real
    /// regression.
    func waitForPollCount(_ expectedCount: Int) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pollCountReached(expectedCount) }
            group.addTask { try? await Task.sleep(for: .seconds(60)) }
            await group.next()
            group.cancelAll()
        }
        return polls.count >= expectedCount
    }

    private func pollCountReached(_ threshold: Int) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if polls.count >= threshold || Task.isCancelled {
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
        let ready = pollWaiters.filter { $0.value.threshold <= polls.count }
        for (waiterID, waiter) in ready {
            pollWaiters.removeValue(forKey: waiterID)
            waiter.continuation.resume()
        }
    }

    private static func response(kind: EpisodeAdAnalysisSpanKind) -> EpisodeAdAnalysisAPIResponse {
        EpisodeAdAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: "polled-response",
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [
                EpisodeAdAnalysisAPIAdSpan(
                    kind: kind,
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
