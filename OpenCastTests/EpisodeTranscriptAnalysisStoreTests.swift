import Foundation
import OpenCastAnalysis
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcript analysis store")
struct EpisodeTranscriptAnalysisStoreTests {
    @Test("Creates the record and document from the producer's answer, then closes the run")
    func createsRecordAndDocumentFromProducer() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        let transcript = makeTranscriptDocument(episodeID: "chapters-create")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        let document = try #require(store.document(for: transcript.episodeID))
        let request = try #require(producer.requests.last)
        #expect(record.chapterCount == 2)
        #expect(record.policy == "transcript_analysis_v2")
        #expect(document.chapters.map(\.title) == ["Welcome", "The Sponsor Read"])
        #expect(document.chapters.map(\.id) == [0, 1])
        #expect(document.chapters[1].startSegmentID == 1)
        #expect(document.summary?.oneLineDescription == "A short test episode")
        #expect(document.transcriptSegmentCount == transcript.segments.count)
        // The run id is the request id, so the document names its run.
        #expect(document.requestID == request.runID)
        #expect(request.analysisRequest.requestID == request.runID)
        #expect(UUID(uuidString: request.runID) != nil)
        #expect(!request.isResume)
        #expect(request.startedByListener)
        #expect(request.transcriptFingerprint == record.transcriptFingerprint)
        // The run closes only once its document is installed.
        #expect(producer.finished == [request.runID])
    }

    @Test("A load closes the open run of an installed document, and only the run that document names")
    func loadClosesTheRunOfAnInstalledDocument() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        let installed = makeTranscriptDocument(episodeID: "chapters-installed")
        let other = makeTranscriptDocument(episodeID: "chapters-other-run")
        for transcript in [installed, other] {
            store.startAnalysis(transcript: transcript, episodeTitle: "Episode", podcastTitle: "Show", modelContext: context)
            #expect(await waitUntil { store.record(for: transcript.episodeID)?.state == .completed })
        }
        let installedRunID = try #require(store.document(for: installed.episodeID)?.requestID)
        // The process stopped after installing the first document but before
        // closing its run; the second episode's open run is not the one its
        // document names.
        for (episodeID, runID) in [(installed.episodeID, installedRunID), (other.episodeID, "a-later-run")] {
            producer.dispatched[episodeID] = ChaptersSummaryDispatchedRun(
                runID: runID,
                transcriptFingerprint: try #require(store.record(for: episodeID)?.transcriptFingerprint),
                startedAt: .now
            )
        }

        store.load(modelContext: context)

        #expect(producer.finishedInstalled == [installedRunID])
        #expect(producer.dispatched[installed.episodeID] == nil)
        // A run the installed document does not name will never resume: it
        // closes as cancelled, never as finished.
        #expect(producer.abandoned == ["a-later-run"])
        #expect(producer.dispatched[other.episodeID] == nil)
        #expect(store.record(for: installed.episodeID)?.state == .completed)
        #expect(store.resumableEpisodeIDs.isEmpty)
    }

    @Test("The request carries both real titles and never the feed address")
    func requestCarriesTitlesNotFeedAddress() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        let transcript = makeTranscriptDocument(
            episodeID: "chapters-titles",
            podcastID: "https://example.com/private-feed.xml"
        )

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil { !store.hasActiveJob })

        let request = try #require(producer.requests.last).analysisRequest
        #expect(request.episodeTitle == "Episode Title")
        #expect(request.podcastTitle == "Podcast Title")
        #expect(request.segments.map(\.id) == [0, 1])
        #expect(request.transcript.segmentCount == 2)
        #expect(request.transcript.state == "completed")
        let policy = try #require(AnalysisPolicySnapshot.baked.chaptersSummary(provider: .google))
        let prompt = ChaptersCanonicalPayload.prompt(request, policy: policy.settings)
        #expect(prompt.contains("Episode: Episode Title\n"))
        #expect(prompt.contains("Podcast: Podcast Title\n"))
        #expect(!prompt.contains(transcript.podcastID))
        #expect(!prompt.contains(transcript.sourceAudioURL))
    }

    @Test("A response from an unexpected policy fails cleanly and closes the run as failed")
    func unexpectedPolicyResponseFailsCleanly() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.policy = "transcript_analysis_v999"
        let transcript = makeTranscriptDocument(episodeID: "chapters-policy")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .generic)
        #expect(record.errorMessage == "Chapters & Summary failed (unexpected_contract).")
        #expect(store.document(for: transcript.episodeID) == nil)
        #expect(producer.failedRuns == producer.requests.map(\.runID))
        #expect(producer.finished.isEmpty)
    }

    @Test("A document that cannot be written keeps the run open and the record running for a resume")
    func installStorageFailureKeepsRunOpen() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let baseDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptAnalysisFileStore(baseDirectory: baseDirectory)
        let (store, producer) = makeStore(fileStore: fileStore)
        let transcript = makeTranscriptDocument(episodeID: "chapters-unwritable")
        // A plain file where the episode's analysis directory belongs makes
        // the document write fail.
        let episodeDirectory = baseDirectory
            .appending(path: EpisodeTranscriptAnalysisFileStore.directoryName)
            .appending(path: fileStore.safeStem(transcript.episodeID))
        try FileManager.default.createDirectory(at: episodeDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: episodeDirectory)

        store.startAnalysis(transcript: transcript, episodeTitle: "Episode", podcastTitle: "Show", modelContext: context)

        #expect(await waitUntil { producer.requests.count == 1 && !store.hasActiveJob })
        let runID = try #require(producer.requests.first?.runID)
        #expect(store.record(for: transcript.episodeID)?.state == .running)
        #expect(store.resumableEpisodeIDs == [transcript.episodeID])
        #expect(producer.finished.isEmpty)
        #expect(producer.failedRuns.isEmpty)
        #expect(producer.abandoned.isEmpty)
        #expect(producer.dispatched[transcript.episodeID]?.runID == runID)
    }

    @Test("Cancelling a resume before its task starts closes the run and ends the record")
    func resumeCancelledBeforeStartIsClosed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        let transcript = makeTranscriptDocument(episodeID: "chapters-cancelled-resume")
        producer.scripted = [.expired]
        store.startAnalysis(transcript: transcript, episodeTitle: "Episode", podcastTitle: "Show", modelContext: context)
        #expect(await waitUntil { producer.requests.count == 1 && !store.hasActiveJob })
        let runID = try #require(producer.dispatched[transcript.episodeID]?.runID)
        #expect(store.resumableEpisodeIDs == [transcript.episodeID])

        store.resumeAnalysis(transcript: transcript, episodeTitle: "Episode", podcastTitle: "Show", modelContext: context)
        store.cancelActiveJob()

        #expect(await waitUntil { !store.hasActiveJob })
        #expect(producer.requests.count == 1)
        #expect(producer.abandoned == [runID])
        #expect(store.record(for: transcript.episodeID)?.state == .failed)
        #expect(store.record(for: transcript.episodeID)?.failureKind == .interrupted)
        #expect(store.resumableEpisodeIDs.isEmpty)
    }

    @Test("A load closes open runs whose records will never resume them")
    func loadClosesStrandedRuns() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: "chapters-failed",
            podcastID: "https://example.com/feed.xml",
            transcriptFingerprint: "fingerprint-failed",
            state: .failed
        ))
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: "chapters-resumable",
            podcastID: "https://example.com/feed.xml",
            transcriptFingerprint: "fingerprint-resumable",
            state: .running,
            analysisRelativePath: "EpisodeTranscriptAnalyses/chapters-resumable/fingerprint.json"
        ))
        try context.save()
        for (episodeID, fingerprint) in [
            ("chapters-failed", "fingerprint-failed"),
            ("chapters-resumable", "fingerprint-resumable"),
            ("chapters-without-record", "fingerprint-gone"),
        ] {
            producer.dispatched[episodeID] = ChaptersSummaryDispatchedRun(
                runID: "run-\(episodeID)",
                transcriptFingerprint: fingerprint,
                startedAt: .now.addingTimeInterval(-60)
            )
        }

        store.load(modelContext: context)

        #expect(Set(producer.abandoned) == ["run-chapters-failed", "run-chapters-without-record"])
        // Usage a failed save left uncounted is counted at every load.
        #expect(producer.unaccountedUsageSweeps == 1)
        #expect(producer.dispatched["chapters-resumable"]?.runID == "run-chapters-resumable")
        #expect(store.resumableEpisodeIDs == ["chapters-resumable"])
    }

    @Test("Deleting a failed analysis closes the run it left open")
    func deletingFailedAnalysisClosesItsRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: "chapters-delete-failed",
            podcastID: "https://example.com/feed.xml",
            transcriptFingerprint: "fingerprint",
            state: .failed
        ))
        try context.save()
        store.load(modelContext: context)
        producer.dispatched["chapters-delete-failed"] = ChaptersSummaryDispatchedRun(
            runID: "run-delete-failed",
            transcriptFingerprint: "fingerprint",
            startedAt: .now
        )

        store.deleteAnalysis(episodeID: "chapters-delete-failed", modelContext: context)

        #expect(producer.abandoned == ["run-delete-failed"])
        #expect(store.record(for: "chapters-delete-failed") == nil)
    }

    @Test("A failed run keeps its kind and its closed message")
    func failedRunKeepsKindAndClosedMessage() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.scripted = [
            .failed(ChaptersSummaryFailureMapping.failure(
                AnalysisFailure(feature: .chaptersSummary, code: .providerRejected, status: 502),
                listenerFailure: .invalidKey
            ))
        ]
        let transcript = makeTranscriptDocument(episodeID: "chapters-invalid-key")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .providerRejectedKey)
        #expect(record.errorMessage == "Chapters & Summary failed (invalid_key).")
        #expect(store.lastErrorMessage(for: transcript.episodeID) == record.errorMessage)
        #expect(store.resumableEpisodeIDs.isEmpty)
        guard case .failed(_, isStale: false) = store.jobState(for: transcript) else {
            Issue.record("A failed run for the current transcript must stay a current failure")
            return
        }
    }

    @Test("A key-required run fails with the reason's kind")
    func keyRequiredRunFailsWithReasonKind() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.scripted = [.failed(ChaptersSummaryFailureMapping.failure(keyRequired: .trialExhausted))]
        let transcript = makeTranscriptDocument(episodeID: "chapters-key-required")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        #expect(record.failureKind == .keyRequiredTrialExhausted)
        #expect(record.failureKind?.keyRequiredReason == .trialExhausted)
    }

    @Test("With no record Generate is offered: the store never reports Chapters & Summary unavailable")
    func noRecordIsReady() throws {
        let (store, _) = makeStore()
        let transcript = makeTranscriptDocument(episodeID: "chapters-ready")
        guard case .ready = store.jobState(for: transcript) else {
            Issue.record("Expected ready, got \(store.jobState(for: transcript))")
            return
        }
    }

    @Test("A completed analysis with no chapters and no summary is never current")
    func contentlessCompletedAnalysisIsNeverCurrent() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.scripted = [
            .completed(
                FakeChaptersSummaryProducer.response(requestID: "contentless", chapters: [], summary: .some(nil)),
                ChaptersSummaryRunCompletion(
                    runID: "contentless",
                    outcome: FakeChaptersSummaryProducer.placeholderOutcome,
                    background: false
                )
            )
        ]
        let transcript = makeTranscriptDocument(episodeID: "chapters-contentless")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: transcript.episodeID))
        #expect(!document.hasPresentableContent)

        let state = await store.episodeDetailState(
            for: transcript,
            transcriptState: .completed,
            analysisDocument: document
        )
        #expect(!state.hasCurrentCompletedAnalysis)
        guard case .completed(_, let isStale) = state.jobState else {
            Issue.record("Expected a completed job state, got \(state.jobState)")
            return
        }
        #expect(!isStale)
        #expect(await !store.hasCurrentCompletedAnalysis(for: transcript))
    }

    @Test("Completed analysis is stale once the transcript changes")
    func completedAnalysisIsStaleOnceTranscriptChanges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, _) = makeStore()
        var transcript = makeTranscriptDocument(episodeID: "chapters-stale")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(await store.hasCurrentCompletedAnalysis(for: transcript))

        transcript.segments[0].text = "A different opening."
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")
        #expect(await !store.hasCurrentCompletedAnalysis(for: transcript))
        guard case .completed(_, isStale: true) = store.jobState(for: transcript) else {
            Issue.record("Expected a stale completed state")
            return
        }
    }

    @Test("A completed analysis whose document was deleted is stale")
    func completedAnalysisWithDeletedDocumentIsStale() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptAnalysisFileStore(baseDirectory: directory)
        let (store, _) = makeStore(fileStore: fileStore)
        let transcript = makeTranscriptDocument(episodeID: "chapters-deleted-document")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil {
            store.record(for: transcript.episodeID)?.state == .completed
        })
        let record = try #require(store.record(for: transcript.episodeID))
        try fileStore.delete(relativePath: record.analysisRelativePath)

        guard case .completed(_, isStale: true) = store.jobState(for: transcript) else {
            Issue.record("A completed record without its document must read as stale")
            return
        }
    }

    @Test("A failure without an output document remains a current, retryable failure after reopening the store")
    func failureWithoutDocumentRemainsCurrentAfterReopening() async throws {
        let directory = try makeTemporaryDirectory()
        let configuration = ModelConfiguration(
            schema: OpenCastModelContainerFactory.localSchema,
            url: directory.appending(path: "LocalDeviceData.store"),
            cloudKitDatabase: .none
        )
        let fileStore = EpisodeTranscriptAnalysisFileStore(baseDirectory: directory)
        let transcript = makeTranscriptDocument(episodeID: "chapters-timeout-relaunch")

        do {
            let container = try ModelContainer(
                for: OpenCastModelContainerFactory.localSchema,
                configurations: [configuration]
            )
            let (store, producer) = makeStore(fileStore: fileStore)
            producer.scripted = [
                .failed(ChaptersSummaryFailureMapping.failure(
                    AnalysisFailure(feature: .chaptersSummary, code: .timeout, status: 503),
                    listenerFailure: .timeout
                ))
            ]
            store.startAnalysis(
                transcript: transcript,
                episodeTitle: "Episode Title",
                podcastTitle: "Podcast Title",
                modelContext: ModelContext(container)
            )
            #expect(await waitUntil {
                !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
            })
            let record = try #require(store.record(for: transcript.episodeID))
            #expect(!fileStore.documentExists(relativePath: record.analysisRelativePath))
            guard case .failed(_, isStale: false) = store.jobState(for: transcript) else {
                Issue.record("A timeout for the current transcript must be a current failure without an output file.")
                return
            }
        }

        let reopenedContainer = try ModelContainer(
            for: OpenCastModelContainerFactory.localSchema,
            configurations: [configuration]
        )
        let (reloadedStore, reloadedProducer) = makeStore(fileStore: fileStore)
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
        #expect(record.failureKind == .timedOut)
        #expect(!detail.hasCurrentCompletedAnalysis)
        #expect(!reloadedStore.hasActiveJob)
        #expect(reloadedProducer.requests.isEmpty)
    }

    @Test("A failure without an output document stays stale when the transcript changes")
    func failureWithoutDocumentStaysStaleForChangedTranscript() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let (store, producer) = makeStore(fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: directory))
        producer.scripted = [.failed(ChaptersSummaryRunFailure(kind: .timedOut, message: "Chapters & Summary failed (timeout)."))]
        var transcript = makeTranscriptDocument(episodeID: "chapters-timeout-changed-transcript")
        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })

        transcript.segments[0].text = "A different episode opening."
        transcript.text = transcript.segments.map(\.text).joined(separator: " ")
        let (reloadedStore, _) = makeStore(fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: directory))
        reloadedStore.load(modelContext: context)
        let detail = await reloadedStore.episodeDetailState(
            for: transcript,
            transcriptState: .completed,
            analysisDocument: nil
        )
        guard case .failed(_, isStale: true) = detail.jobState else {
            Issue.record("A failure for different transcript content must remain stale.")
            return
        }
    }

    @Test("An active job never marks other episodes as running")
    func activeJobNeverMarksOtherEpisodesRunning() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.holdsRuns = true
        let runningTranscript = makeTranscriptDocument(episodeID: "chapters-running-a")
        let otherTranscript = makeTranscriptDocument(episodeID: "chapters-idle-b")

        store.startAnalysis(
            transcript: runningTranscript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(store.isRunning(for: runningTranscript.episodeID))
        #expect(await waitUntil { producer.isHolding })

        guard case .running = store.jobState(for: runningTranscript) else {
            Issue.record("Expected the active episode to report running")
            return
        }
        #expect(!store.isRunning(for: otherTranscript.episodeID))
        guard case .ready = store.jobState(for: otherTranscript) else {
            Issue.record("Expected the uninvolved episode to stay ready, got \(store.jobState(for: otherTranscript))")
            return
        }
        // The run in flight is never offered for resume.
        #expect(store.resumableEpisodeIDs.isEmpty)

        producer.release()
        #expect(await waitUntil { !store.hasActiveJob })
    }

    @Test("Deleting the analysis mid-run cancels it and leaves nothing to resume")
    func deleteMidRunCancels() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.holdsRuns = true
        let transcript = makeTranscriptDocument(episodeID: "chapters-delete-mid-run")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil { producer.isHolding })
        let runID = try #require(producer.requests.last?.runID)

        store.deleteAnalysis(episodeID: transcript.episodeID, modelContext: context)

        #expect(await waitUntil { !store.hasActiveJob })
        #expect(producer.cancelledRunIDs == [runID])
        #expect(store.record(for: transcript.episodeID) == nil)
        #expect(store.resumableEpisodeIDs.isEmpty)
        #expect(producer.finished.isEmpty)
    }

    @Test("A cancelled run ends its record as interrupted, never resumable")
    func cancelledRunEndsRecordInterrupted() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        producer.holdsRuns = true
        let transcript = makeTranscriptDocument(episodeID: "chapters-cancel")

        store.startAnalysis(
            transcript: transcript,
            episodeTitle: "Episode Title",
            podcastTitle: "Podcast Title",
            modelContext: context
        )
        #expect(await waitUntil { producer.isHolding })

        store.cancelActiveJob()

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .failed
        })
        #expect(store.record(for: transcript.episodeID)?.failureKind == .interrupted)
        #expect(store.resumableEpisodeIDs.isEmpty)
    }

    @Test("Deferrals an earlier build left demote at every load, acknowledged or not")
    func deferralsDemoteAtEveryLoad() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, _) = makeStore()
        store.acknowledgeGenerateDisclosure(modelContext: context)
        for (episodeID, kind) in [
            ("chapters-cap", EpisodeAnalysisFailureKind.capExceeded),
            ("chapters-402", .insufficientSeconds),
            ("chapters-timeout", .timedOut)
        ] {
            let record = EpisodeTranscriptAnalysisRecord(
                episodeID: episodeID,
                podcastID: "https://example.com/feed.xml",
                state: .failed,
                errorMessage: "Deferred by the worker."
            )
            record.failureKind = kind
            context.insert(record)
        }
        try context.save()

        store.load(modelContext: context)

        #expect(store.hasAcknowledgedGenerateDisclosure)
        #expect(store.record(for: "chapters-cap")?.failureKind == .generic)
        #expect(store.record(for: "chapters-402")?.failureKind == .generic)
        #expect(store.record(for: "chapters-timeout")?.failureKind == .timedOut)
        #expect(store.records.allSatisfy { $0.state == .failed })
        #expect(store.resumableEpisodeIDs.isEmpty)
    }

    @Test("A launch keeps a dispatched device run and fails a running record with no run")
    func launchKeepsDispatchedDeviceRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, producer) = makeStore()
        for episodeID in ["chapters-dispatched", "chapters-orphan", "chapters-old-run"] {
            context.insert(EpisodeTranscriptAnalysisRecord(
                episodeID: episodeID,
                podcastID: "https://example.com/feed.xml",
                transcriptFingerprint: "fingerprint-\(episodeID)",
                state: .running,
                analysisRelativePath: "EpisodeTranscriptAnalyses/\(episodeID)/fingerprint.json"
            ))
        }
        try context.save()
        producer.dispatched["chapters-dispatched"] = ChaptersSummaryDispatchedRun(
            runID: "run-dispatched",
            transcriptFingerprint: "fingerprint-chapters-dispatched",
            startedAt: .now.addingTimeInterval(-120)
        )
        producer.dispatched["chapters-old-run"] = ChaptersSummaryDispatchedRun(
            runID: "run-old",
            transcriptFingerprint: "fingerprint-chapters-old-run",
            startedAt: .now.addingTimeInterval(-7_200)
        )

        store.load(modelContext: context)

        #expect(store.record(for: "chapters-dispatched")?.state == .running)
        #expect(store.resumableEpisodeIDs == ["chapters-dispatched"])
        #expect(store.record(for: "chapters-orphan")?.state == .failed)
        #expect(store.record(for: "chapters-old-run")?.state == .failed)
        #expect(producer.requests.isEmpty)
        guard case .running = store.jobState(for: makeTranscriptDocument(episodeID: "chapters-dispatched")) else {
            Issue.record("A dispatched run keeps its spinner until it resumes")
            return
        }
    }

    @Test("A service job accepted before the update drains to completion by polling only")
    func acceptedServiceJobDrains() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptAnalysisFileStore(baseDirectory: directory)
        let transcript = makeTranscriptDocument(episodeID: "chapters-drain")
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcript.segments)
        let fingerprint = fileStore.transcriptFingerprint(for: transcript, segments: segments)
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: segments.count,
            state: .running,
            analysisRelativePath: fileStore.relativePath(episodeID: transcript.episodeID, transcriptFingerprint: fingerprint),
            // Two hours: past the device-run window, inside the day the
            // service keeps a finished result.
            jobAcceptedAt: .now.addingTimeInterval(-7_200)
        ))
        try context.save()
        let client = ScriptedTranscriptAnalysisDrainClient([
            .failure(EpisodeTranscriptAnalysisHTTPError(statusCode: 503, code: "job_unavailable", detail: nil)),
            .success(.completed(FakeChaptersSummaryProducer.response(requestID: "service-job")))
        ])
        let (store, producer) = makeStore(client: client, fileStore: fileStore)

        store.load(modelContext: context)

        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: transcript.episodeID)?.state == .completed
        })
        #expect(client.polledJobIDs == [fingerprint, fingerprint])
        #expect(producer.requests.isEmpty)
        #expect(store.document(for: transcript.episodeID)?.chapters.count == 2)
    }

    @Test("A service job older than a day fails without a poll, and a drain failure keeps only its code")
    func staleServiceJobFailsAndDrainMessagesAreClosed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptAnalysisFileStore(baseDirectory: directory)
        for (episodeID, acceptedAgo) in [("chapters-stale-job", 90_000.0), ("chapters-failing-job", 60.0)] {
            context.insert(EpisodeTranscriptAnalysisRecord(
                episodeID: episodeID,
                podcastID: "https://example.com/feed.xml",
                transcriptFingerprint: "fingerprint-\(episodeID)",
                state: .running,
                analysisRelativePath: "EpisodeTranscriptAnalyses/\(episodeID)/fingerprint.json",
                jobAcceptedAt: .now.addingTimeInterval(-acceptedAgo)
            ))
        }
        try context.save()
        let client = ScriptedTranscriptAnalysisDrainClient([
            .failure(EpisodeTranscriptAnalysisHTTPError(
                statusCode: 502,
                code: "invalid_model_output",
                detail: "provider said: Welcome back to the show"
            ))
        ])
        let (store, _) = makeStore(client: client, fileStore: fileStore)

        store.load(modelContext: context)

        #expect(store.record(for: "chapters-stale-job")?.state == .failed)
        #expect(await waitUntil {
            !store.hasActiveJob && store.record(for: "chapters-failing-job")?.state == .failed
        })
        #expect(client.polledJobIDs == ["fingerprint-chapters-failing-job"])
        let message = try #require(store.record(for: "chapters-failing-job")?.errorMessage)
        #expect(message == "Chapters & Summary failed (invalid_model_output).")
    }

    @Test("Generate disclosure copy names the provider, the trial service and never minutes")
    func generateDisclosureCopy() {
        let body = TranscriptAnalysisGenerateDisclosureCopy.confirmationBody()
        #expect(body == """
        This episode’s transcript text is sent to the AI provider you chose, using your key, to generate chapters and a summary. Without a key, it goes through opencast’s trial service. Your audio is never sent.
        Results are saved on this device.
        """)
        #expect(!body.contains("minutes"))
        #expect(!body.contains("shared"))
        #expect(!TranscriptAnalysisFeatureFlags.chargesTranscriptionMinutes)
        #expect(TranscriptAnalysisGenerateDisclosureCopy.confirmationBody(chargesTranscriptionMinutes: true)
            .hasSuffix("\nUses transcription minutes."))
        #expect(TranscriptAnalysisGenerateDisclosureCopy.title == "Generate Chapters & Summary?")
        #expect(TranscriptAnalysisGenerateDisclosureCopy.confirmButtonTitle == "Generate")
    }

    @Test("The disclosure acknowledgement persists across loads")
    func disclosureAcknowledgementPersists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let (store, _) = makeStore()
        #expect(!store.hasAcknowledgedGenerateDisclosure)
        store.acknowledgeGenerateDisclosure(modelContext: context)

        let (reloaded, _) = makeStore()
        reloaded.load(modelContext: context)
        #expect(reloaded.hasAcknowledgedGenerateDisclosure)
    }

    // MARK: - Queue

    @Test("A card expiry in the background leaves the record running; the next activation resumes the same run")
    func expiredRunResumesWithSameRunIDOnActivation() async throws {
        let harness = try await makeQueueHarness(slug: "expiry")
        let producer = harness.producer
        producer.scripted = [.expired]
        let episodeID = harness.episodeIDs[0]
        harness.appModel.isSceneActive = false

        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)
        #expect(await waitUntil {
            producer.requests.count == 1 && !harness.store.hasActiveJob
        })
        #expect(harness.store.record(for: episodeID)?.state == .running)
        #expect(harness.store.resumableEpisodeIDs == [episodeID])
        let first = try #require(producer.requests.first)
        #expect(first.startedByListener)

        harness.appModel.isSceneActive = true
        harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: harness.context)

        #expect(await waitUntil {
            harness.store.record(for: episodeID)?.state == .completed
        })
        #expect(producer.requests.count == 2)
        let resumed = try #require(producer.requests.last)
        #expect(resumed.isResume)
        #expect(!resumed.startedByListener)
        #expect(resumed.runID == first.runID)
        #expect(resumed.analysisRequest.requestID == first.runID)
        #expect(producer.finished == [first.runID])
        #expect(harness.store.resumableEpisodeIDs.isEmpty)
    }

    @Test("A Generate waits behind an interrupted run, which resumes first at the next activation")
    func generateWaitsBehindInterruptedRun() async throws {
        let harness = try await makeQueueHarness(slug: "hold", episodeCount: 2)
        let producer = harness.producer
        producer.scripted = [.expired]
        let first = harness.episodeIDs[0]
        let second = harness.episodeIDs[1]
        harness.appModel.isSceneActive = false
        harness.appModel.generateChaptersAndSummary(episodeID: first, modelContext: harness.context)
        #expect(await waitUntil { producer.requests.count == 1 && !harness.store.hasActiveJob })
        #expect(harness.store.resumableEpisodeIDs == [first])

        harness.appModel.generateChaptersAndSummary(episodeID: second, modelContext: harness.context)
        try await Task.sleep(for: .milliseconds(200))
        // Never two interrupted runs: the second waits.
        #expect(producer.requests.count == 1)
        #expect(harness.store.record(for: second) == nil)

        harness.appModel.isSceneActive = true
        harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: harness.context)

        #expect(await waitUntil {
            harness.store.record(for: first)?.state == .completed
                && harness.store.record(for: second)?.state == .completed
        })
        #expect(producer.requests.map(\.episodeID) == [first, first, second])
        #expect(producer.requests.map(\.isResume) == [false, true, false])
    }

    @Test("A card expiry while the app is in the foreground resumes at once")
    func expiryInForegroundResumesAtOnce() async throws {
        let harness = try await makeQueueHarness(slug: "expiry-foreground")
        let producer = harness.producer
        producer.scripted = [.expired]
        let episodeID = harness.episodeIDs[0]

        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)

        #expect(await waitUntil {
            harness.store.record(for: episodeID)?.state == .completed
        })
        #expect(producer.requests.map(\.isResume) == [false, true])
        #expect(Set(producer.requests.map(\.runID)).count == 1)
    }

    @Test("Activations while a run is in flight queue nothing, and a run that ended is never resumed")
    func activationsDuringRunQueueNothing() async throws {
        let harness = try await makeQueueHarness(slug: "activation-during-run")
        let producer = harness.producer
        producer.holdsRuns = true
        producer.scripted = [.failed(ChaptersSummaryRunFailure(kind: .timedOut, message: "Chapters & Summary failed (timeout)."))]
        let episodeID = harness.episodeIDs[0]

        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)
        #expect(await waitUntil { producer.isHolding })
        for _ in 0..<3 {
            harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: harness.context)
        }
        #expect(harness.store.resumableEpisodeIDs.isEmpty)

        producer.release()
        #expect(await waitUntil {
            !harness.store.hasActiveJob && harness.store.record(for: episodeID)?.state == .failed
        })
        harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: harness.context)
        try await Task.sleep(for: .milliseconds(200))
        #expect(producer.requests.count == 1)
    }

    @Test("A resume past the window ends the record as interrupted and closes the run without a send")
    func resumePastWindowIsAbandoned() async throws {
        let harness = try await makeQueueHarness(slug: "resume-window")
        let producer = harness.producer
        producer.scripted = [.expired]
        let episodeID = harness.episodeIDs[0]
        harness.appModel.isSceneActive = false
        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)
        #expect(await waitUntil { producer.requests.count == 1 && !harness.store.hasActiveJob })
        let run = try #require(producer.dispatched[episodeID])
        producer.dispatched[episodeID] = ChaptersSummaryDispatchedRun(
            runID: run.runID,
            transcriptFingerprint: run.transcriptFingerprint,
            startedAt: .now.addingTimeInterval(-7_200)
        )

        harness.appModel.isSceneActive = true
        harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: harness.context)

        #expect(await waitUntil {
            harness.store.record(for: episodeID)?.state == .failed
        })
        #expect(harness.store.record(for: episodeID)?.failureKind == .interrupted)
        #expect(producer.abandoned == [run.runID])
        #expect(producer.requests.count == 1)
    }

    @Test("A resume whose transcript changed ends the record as interrupted and closes the run")
    func resumeAfterTranscriptChangeIsAbandoned() async throws {
        let harness = try await makeQueueHarness(slug: "resume-changed")
        let producer = harness.producer
        producer.scripted = [.expired]
        let episodeID = harness.episodeIDs[0]
        harness.appModel.isSceneActive = false
        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)
        #expect(await waitUntil { producer.requests.count == 1 && !harness.store.hasActiveJob })
        let run = try #require(producer.dispatched[episodeID])
        producer.dispatched[episodeID] = ChaptersSummaryDispatchedRun(
            runID: run.runID,
            transcriptFingerprint: "a-different-transcript",
            startedAt: run.startedAt
        )

        harness.appModel.isSceneActive = true
        harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: harness.context)

        #expect(await waitUntil {
            !harness.store.hasActiveJob && harness.store.record(for: episodeID)?.state == .failed
        })
        #expect(harness.store.record(for: episodeID)?.failureKind == .interrupted)
        #expect(producer.abandoned == [run.runID])
        #expect(producer.requests.count == 1)
    }

    @Test("A queued resume whose episode left the library ends as interrupted")
    func resumeForUnresolvableEpisodeIsAbandoned() async throws {
        let harness = try await makeQueueHarness(slug: "resume-gone", episodeCount: 1)
        let producer = harness.producer
        let context = harness.context
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: "episode-not-in-library",
            podcastID: "https://example.com/elsewhere.xml",
            transcriptFingerprint: "fingerprint",
            state: .running,
            analysisRelativePath: "EpisodeTranscriptAnalyses/episode-not-in-library/fingerprint.json"
        ))
        try context.save()
        producer.dispatched["episode-not-in-library"] = ChaptersSummaryDispatchedRun(
            runID: "run-gone",
            transcriptFingerprint: "fingerprint",
            startedAt: .now
        )
        harness.store.load(modelContext: context)
        #expect(harness.store.resumableEpisodeIDs == ["episode-not-in-library"])

        harness.appModel.resumeInterruptedTranscriptAnalyses(modelContext: context)

        #expect(await waitUntil {
            harness.store.record(for: "episode-not-in-library")?.state == .failed
        })
        #expect(producer.abandoned == ["run-gone"])
        #expect(producer.requests.isEmpty)
    }

    @Test("Generate skips an episode whose current analysis already completed")
    func generateSkipsCurrentAnalysis() async throws {
        let harness = try await makeQueueHarness(slug: "skip-current")
        let producer = harness.producer
        let episodeID = harness.episodeIDs[0]

        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)
        #expect(await waitUntil { harness.store.record(for: episodeID)?.state == .completed })
        harness.appModel.generateChaptersAndSummary(episodeID: episodeID, modelContext: harness.context)
        try await Task.sleep(for: .milliseconds(200))

        #expect(producer.requests.count == 1)
    }

    // MARK: - Unchanged surfaces

    @Test("Transcript analysis record is local-only but included in full schema")
    func transcriptAnalysisRecordIsLocalOnly() {
        let localEntityNames = OpenCastModelContainerFactory.localSchema.entities.map(\.name)
        let syncedEntityNames = OpenCastModelContainerFactory.syncedSchema.entities.map(\.name)
        let fullEntityNames = OpenCastModelContainerFactory.fullSchema.entities.map(\.name)
        #expect(localEntityNames.contains("EpisodeTranscriptAnalysisRecord"))
        #expect(!syncedEntityNames.contains("EpisodeTranscriptAnalysisRecord"))
        #expect(fullEntityNames.contains("EpisodeTranscriptAnalysisRecord"))
    }

    @Test("Duplicate repair OR-merges the opt-in onto the deterministic winner")
    func duplicateRepairORMergesOptIn() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/chapters-merge.xml"

        // The winner (smallest dedupeUUID) has the flag OFF; a losing twin
        // carries the explicit opt-in. The merge must keep the winner row and
        // the consent.
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Winner Copy",
                isTranscriptAnalysisEnabled: false,
                dedupeUUID: "aaaaaaaa-0000-0000-0000-000000000000"
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Loser Copy",
                isTranscriptAnalysisEnabled: true,
                dedupeUUID: "bbbbbbbb-0000-0000-0000-000000000000"
            )
        )
        try context.save()

        _ = try await store.repairSyncDuplicates(modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.count == 1)
        let survivor = try #require(subscriptions.first)
        #expect(survivor.dedupeUUID == "aaaaaaaa-0000-0000-0000-000000000000")
        #expect(survivor.isTranscriptAnalysisEnabled == true)
    }

    @Test("Legacy duplicate replacement carries the opt-in onto the fresh record")
    func legacyDuplicateReplacementCarriesOptIn() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/chapters-legacy-merge.xml"

        context.insert(
            SubscriptionRecord(feedURL: feedURL, title: "Legacy Off", isTranscriptAnalysisEnabled: false, dedupeUUID: "")
        )
        context.insert(
            SubscriptionRecord(feedURL: feedURL, title: "Legacy On", isTranscriptAnalysisEnabled: true, dedupeUUID: "")
        )
        try context.save()

        _ = try await store.repairSyncDuplicates(modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.count == 1)
        let survivor = try #require(subscriptions.first)
        #expect(!survivor.dedupeUUID.isEmpty)
        #expect(survivor.isTranscriptAnalysisEnabled == true)
    }

    @Test("Episode detail snapshot threads the creator chapters URL")
    func episodeDetailSnapshotThreadsChaptersURL() async throws {
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let feedURL = URL(string: "https://example.com/chaptered-cache.xml")!
        let snapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>Chaptered Cache Show</title>
                    <item>
                      <title>With Chapters</title>
                      <guid>cache-chaptered-1</guid>
                      <podcast:chapters url="https://example.com/chapters/cache-1.json" type="application/json+chapters" />
                      <enclosure url="https://example.com/audio/cache-1.mp3" type="audio/mpeg" />
                    </item>
                    <item>
                      <title>Without Chapters</title>
                      <guid>cache-chaptered-2</guid>
                      <enclosure url="https://example.com/audio/cache-2.mp3" type="audio/mpeg" />
                    </item>
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: feedURL
        )
        try await cache.upsertCache(from: snapshot, refreshedAt: .now)

        let chaptered = try #require(
            await cache.episodeDetail(episodeID: snapshot.episodes[0].id.rawValue)
        )
        #expect(chaptered.chaptersURL == "https://example.com/chapters/cache-1.json")
        let plain = try #require(
            await cache.episodeDetail(episodeID: snapshot.episodes[1].id.rawValue)
        )
        #expect(plain.chaptersURL == nil)
    }

    // MARK: - Helpers

    private func makeStore(
        client: any EpisodeTranscriptAnalysisClient = ScriptedTranscriptAnalysisDrainClient(),
        fileStore: EpisodeTranscriptAnalysisFileStore? = nil
    ) -> (EpisodeTranscriptAnalysisStore, FakeChaptersSummaryProducer) {
        let store = EpisodeTranscriptAnalysisStore(
            client: client,
            fileStore: fileStore ?? EpisodeTranscriptAnalysisFileStore(baseDirectory: try! makeTemporaryDirectory()),
            pollingSleep: { _ in }
        )
        let producer = FakeChaptersSummaryProducer()
        producer.attach(to: store)
        return (store, producer)
    }

    private func makeQueueHarness(slug: String, episodeCount: Int = 1) async throws -> QueueHarness {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriptAnalyses = EpisodeTranscriptAnalysisStore(
            client: ScriptedTranscriptAnalysisDrainClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: temporaryDirectory)
        )
        let items = (0..<episodeCount).map { index in
            """
                <item>
                  <title>Episode \(index)</title>
                  <guid>\(slug)-\(index)</guid>
                  <enclosure url="https://example.com/audio/\(slug)-\(index).mp3" type="audio/mpeg" />
                </item>
            """
        }.joined(separator: "\n")
        let snapshot = try RSSFeedParser().parse(
            data: Data(
                """
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0">
                  <channel>
                    <title>\(slug) Show</title>
                \(items)
                  </channel>
                </rss>
                """.utf8
            ),
            feedURL: URL(string: "https://example.com/\(slug).xml")!
        )
        try await localCache.upsertCache(from: snapshot, refreshedAt: .now)
        let feedURL = snapshot.podcast.id.rawValue
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "\(slug) Show"))
        let episodeIDs = snapshot.episodes.map(\.id.rawValue)
        for episodeID in episodeIDs {
            try seedCompletedTranscript(
                episodeID: episodeID,
                podcastID: feedURL,
                fileStore: transcriptFileStore,
                context: context
            )
        }
        try context.save()

        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: localCache),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            transcriptAnalyses: transcriptAnalyses,
            analysisRuns: AnalysisRunRecordStore(directory: temporaryDirectory.appending(path: "AnalysisRuns")),
            allowsAutomaticFeedRefresh: false
        )
        let producer = FakeChaptersSummaryProducer()
        producer.attach(to: transcriptAnalyses)
        await appModel.library.load(modelContext: context)
        appModel.transcriptions.load(modelContext: context)
        transcriptAnalyses.load(modelContext: context)
        transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: context)
        return QueueHarness(
            appModel: appModel,
            context: context,
            store: transcriptAnalyses,
            producer: producer,
            episodeIDs: episodeIDs
        )
    }

    private func makeTranscriptDocument(
        episodeID: String,
        podcastID: String = "https://example.com/feed.xml",
        audioDuration: Double = 16,
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> EpisodeTranscriptDocument {
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
            podcastID: podcastID,
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 987_654_321,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: audioDuration,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    private func seedCompletedTranscript(
        episodeID: String,
        podcastID: String,
        audioDuration: Double = 16,
        fileStore: EpisodeTranscriptFileStore,
        context: ModelContext
    ) throws {
        let document = makeTranscriptDocument(
            episodeID: episodeID,
            podcastID: podcastID,
            audioDuration: audioDuration
        )
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentifier: document.modelIdentifier,
            modelVersion: document.modelVersion,
            modelTreeSHA256: document.modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: episodeID, fingerprint: fingerprint)
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: episodeID,
            podcastID: podcastID,
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
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptAnalysisTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private struct QueueHarness {
    let appModel: OpenCastAppModel
    let context: ModelContext
    let store: EpisodeTranscriptAnalysisStore
    let producer: FakeChaptersSummaryProducer
    let episodeIDs: [String]
}
