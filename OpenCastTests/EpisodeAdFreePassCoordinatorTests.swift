import Foundation
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad-free pass coordinator")
struct EpisodeAdFreePassCoordinatorTests {
    @Test("Outdated presentation offers a manual re-run with settled copy")
    func outdatedPresentationOffersManualRerun() {
        let outdated = EpisodeAdFreePassPresentation.outdated
        #expect(outdated.statusText == "Outdated — run again")
        #expect(outdated.primaryActionTitle == "Skip Promos & Ads")
        #expect(outdated.isPrimaryActionEnabled)
        #expect(outdated.stage == .idle)
        #expect(EpisodeAdAnalysisControlsView.outdatedStatusTitle == "Outdated — run again")
    }

    @Test("First tap downloads episode and parks at model consent; second tap finishes transcript and analysis")
    func consentThenCompletesOneTapPass() async throws {
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            modelInstalled: false
        )
        let episode = makeEpisode(episodeID: "ad-free-consent")
        var refreshCount = 0

        fixture.enqueue(episode, refreshSkipZones: {
            refreshCount += 1
            return 1
        })

        #expect(await waitUntil {
            fixture.coordinator.pendingModelConsentEpisodeID == episode.episodeID
        })
        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .completed)
        #expect(fixture.coordinator.pendingModelConsentByteCount == 78_900_000)
        #expect(fixture.coordinator.queueState == .awaitingModelConsent)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [episode.episodeID])
        let consentPresentation = fixture.presentation(for: episode)
        #expect(consentPresentation.stage == .awaitingModelDownloadConsent(byteCount: 78_900_000))
        #expect(consentPresentation.primaryActionTitle.contains("Download Model"))

        fixture.enqueue(episode, refreshSkipZones: {
            refreshCount += 1
            return 1
        })

        #expect(await waitUntil {
            fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed
                && fixture.coordinator.activeEpisodeID == nil
        })
        #expect(fixture.modelInstaller.installCallCount == 1)
        #expect(fixture.transcriptions.document(for: episode.episodeID) != nil)
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)
        #expect(refreshCount == 1)
        #expect(fixture.coordinator.queueState == .idle)
        #expect(await waitUntil {
            fixture.presentation(for: episode, currentZoneCount: 1).stage
                == .completed(zoneCount: 1)
        })
    }

    @Test("Queue drains FIFO with manual tail order, auto front insertion, and no preemption")
    func queueDrainsFIFOWithAutoFrontInsertion() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let first = makeEpisode(episodeID: "queue-fifo-1")
        let second = makeEpisode(episodeID: "queue-fifo-2")
        let third = makeEpisode(episodeID: "queue-fifo-3")
        let autoFront = makeEpisode(episodeID: "queue-fifo-auto")
        var preparedTitles: [String] = []

        fixture.enqueue(first, prepare: { preparedTitles.append(first.title) })
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == first.episodeID
        })

        fixture.enqueue(second, prepare: { preparedTitles.append(second.title) })
        fixture.enqueue(third, prepare: { preparedTitles.append(third.title) })
        fixture.enqueue(autoFront, origin: .auto)

        #expect(fixture.coordinator.activeEpisodeID == first.episodeID)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [
            autoFront.episodeID, second.episodeID, third.episodeID
        ])
        #expect(await waitUntil {
            preparedTitles.count == 3
        })
        #expect(fixture.coordinator.queueStatus(for: second.episodeID) == .queued(ahead: 2))
        #expect(fixture.presentation(for: second).statusText == "Queued — 2 ahead")
        #expect(fixture.coordinator.queueStatus(for: first.episodeID) == .running)

        for episode in [first, second, third, autoFront] {
            downloader.release(urlContaining: episode.episodeID)
        }

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 4
        })
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [
            first.episodeID, autoFront.episodeID, second.episodeID, third.episodeID
        ])
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 4)
    }

    @Test("A per-episode failure records the outcome and the queue continues")
    func failureIsolationContinuesQueue() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answerForRun = { run in
            run == 2 ? .failure(.rejected(status: 400), status: 400, listener: .requestRejected) : nil
        }
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        let first = makeEpisode(episodeID: "queue-isolation-1")
        let second = makeEpisode(episodeID: "queue-isolation-2")
        let third = makeEpisode(episodeID: "queue-isolation-3")
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        fixture.enqueue(second)
        fixture.enqueue(third)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 3
        })
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [
            first.episodeID, second.episodeID, third.episodeID
        ])
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.state == .completed)
        #expect(fixture.adAnalyses.record(for: second.episodeID)?.state == .failed)
        #expect(fixture.adAnalyses.record(for: third.episodeID)?.state == .completed)
        guard case .failed(let message) = fixture.coordinator.queueStatus(for: second.episodeID) else {
            Issue.record("expected failed status for the second episode")
            return
        }
        #expect(!message.isEmpty)
        #expect(terminals == [.drained(completedCount: 2, failedCount: 1)])
    }

    @Test("hasCurrentCompletedAnalysis caches an off-main verdict keyed by record stamps")
    func hasCurrentCompletedAnalysisCachesOffMainVerdict() async throws {
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        )
        let episode = makeEpisode(episodeID: "ad-free-verdict-cache")
        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed
                && fixture.coordinator.activeEpisodeID == nil
        })

        // The first read may be a provisional false.
        #expect(await waitUntil {
            fixture.coordinator.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses
            )
        })

        // A new record stamp makes the next read provisional again.
        fixture.transcriptions.record(for: episode.episodeID)?.updatedAt =
            Date.now.addingTimeInterval(60)
        #expect(
            !fixture.coordinator.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses
            )
        )
        #expect(await waitUntil {
            fixture.coordinator.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses
            )
        })
    }

    @Test("Re-enqueueing an already queued or already active episode is idempotent")
    func enqueueIsIdempotentForQueuedAndActiveEpisodes() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let first = makeEpisode(episodeID: "queue-idempotent-1")
        let second = makeEpisode(episodeID: "queue-idempotent-2")
        var prepareCount = 0

        fixture.enqueue(first, prepare: { prepareCount += 1 })
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == first.episodeID
        })
        fixture.enqueue(first, prepare: { prepareCount += 1 })
        fixture.enqueue(second, prepare: { prepareCount += 1 })
        fixture.enqueue(second, prepare: { prepareCount += 1 })

        #expect(await waitUntil {
            prepareCount == 2
        })
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [second.episodeID])

        downloader.release(urlContaining: first.episodeID)
        downloader.release(urlContaining: second.episodeID)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
    }

    @Test("Model consent pauses the whole queue and the consent tap resumes the drain")
    func consentPausesQueueAndResumes() async throws {
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            modelInstalled: false
        )
        let first = makeEpisode(episodeID: "queue-consent-1")
        let second = makeEpisode(episodeID: "queue-consent-2")
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        fixture.enqueue(second)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .awaitingModelConsent
        })
        #expect(fixture.coordinator.pendingModelConsentEpisodeID == first.episodeID)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [first.episodeID, second.episodeID])
        #expect(terminals == [.awaitingConsent])

        fixture.enqueue(first)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(fixture.modelInstaller.installCallCount == 1)
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.state == .completed)
        #expect(fixture.adAnalyses.record(for: second.episodeID)?.state == .completed)
        #expect(terminals == [.awaitingConsent, .drained(completedCount: 2, failedCount: 0)])
    }

    @Test("Cancel interrupts the active item, pauses the queue, and a re-tap resumes from the front")
    func cancelPausesQueueAndRetapResumes() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let first = makeEpisode(episodeID: "queue-cancel-1")
        let second = makeEpisode(episodeID: "queue-cancel-2")
        var stages: [EpisodeAdFreePassStage] = []
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onStageChange = { stage, _ in stages.append(stage) }
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        fixture.enqueue(second)
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == first.episodeID
        })

        fixture.coordinator.cancelActivePass()

        #expect(await waitUntil {
            fixture.coordinator.queueState == .pausedInterrupted
        })
        #expect(stages.contains(.interrupted))
        #expect(terminals == [.interrupted])
        #expect(fixture.coordinator.activeEpisodeID == nil)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [second.episodeID])
        #expect(!fixture.coordinator.isQueuePausedForEnvironmentalInterrupt)

        downloader.release(urlContaining: first.episodeID)
        downloader.release(urlContaining: second.episodeID)
        fixture.enqueue(first)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [first.episodeID, second.episodeID])
    }

    @Test("Cancelling a single-item queue leaves an idle, re-tappable coordinator")
    func cancelSingleItemQueueReturnsToIdle() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let episode = makeEpisode(episodeID: "queue-cancel-single")

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == episode.episodeID
        })

        fixture.coordinator.cancelActivePass()

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.activeEpisodeID == nil
        })
        #expect(fixture.coordinator.queueItems.isEmpty)

        downloader.release(urlContaining: episode.episodeID)
        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed
        })
    }

    @Test("An environmental interrupt holds the item, pauses the queue, and the auto-resume seam drains it")
    func environmentalInterruptHoldsItemAndAutoResumeDrains() async throws {
        let transcriber = ComputeFailureEpisodeTranscriber(failingRequestCount: 2)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            )
        )
        let first = makeEpisode(episodeID: "queue-environmental-1")
        let second = makeEpisode(episodeID: "queue-environmental-2")
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        fixture.enqueue(second)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .pausedInterrupted
        })
        #expect(fixture.coordinator.isQueuePausedForEnvironmentalInterrupt)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [first.episodeID, second.episodeID])
        #expect(fixture.transcriptions.hasEnvironmentalInterruptionPending(for: first.episodeID))
        #expect(terminals == [.interrupted])

        fixture.coordinator.resumeQueueForEnvironmentalAutoResume()

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.state == .completed)
        #expect(fixture.adAnalyses.record(for: second.episodeID)?.state == .completed)
    }

    @Test("A cpuOnly fallback inside a protected drain sticks for subsequent whisper items")
    func stickyDegradedComputeCarriesAcrossProtectedDrain() async throws {
        let transcriber = ComputeFailureEpisodeTranscriber(failsDefaultComputeOnly: true)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            )
        )
        fixture.coordinator.isBackgroundProtected = { true }
        let first = makeEpisode(episodeID: "queue-sticky-1")
        let second = makeEpisode(episodeID: "queue-sticky-2")

        fixture.enqueue(first)
        fixture.enqueue(second)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(transcriber.requestProfiles(forURLContaining: first.episodeID) == [.backgroundSafe, .cpuOnly])
        #expect(transcriber.requestProfiles(forURLContaining: second.episodeID) == [.cpuOnly])
    }

    @Test("A GPU-less session selects non-GPU compute for the actual transcription request")
    func gpuLessSessionPinsTranscriptionCompute() async throws {
        let transcriber = ComputeFailureEpisodeTranscriber()
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber
        )
        fixture.coordinator.requiresNonGPUCompute = { true }
        let episode = makeEpisode(episodeID: "queue-no-gpu")
        fixture.enqueue(episode, engine: .selectedWhisperModel)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1
        })
        #expect(transcriber.requestProfiles(forURLContaining: episode.episodeID) == [.cpuAndNeuralEngine])
    }

    @Test("Foreground return mid-drain resets the sticky degraded compute profile")
    func foregroundReturnResetsStickyComputeMidDrain() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let transcriber = ComputeFailureEpisodeTranscriber(failsDefaultComputeOnly: true)
        let fixture = try await makeFixture(
            downloader: downloader,
            transcriber: transcriber,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            )
        )
        fixture.coordinator.isBackgroundProtected = { true }
        let first = makeEpisode(episodeID: "queue-sticky-reset-1")
        let second = makeEpisode(episodeID: "queue-sticky-reset-2")

        fixture.enqueue(first)
        fixture.enqueue(second)
        downloader.release(urlContaining: first.episodeID)

        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == second.episodeID
        })
        #expect(transcriber.requestProfiles(forURLContaining: first.episodeID) == [.backgroundSafe, .cpuOnly])

        fixture.coordinator.handleForegroundReturn()
        downloader.release(urlContaining: second.episodeID)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(transcriber.requestProfiles(forURLContaining: second.episodeID) == [.backgroundSafe, .cpuOnly])
    }

    @Test("Pending queue items persist, restore as queued in order, and drop unresolvable records")
    func persistenceRoundTripRestoresPendingItems() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(
            downloader: downloader,
            container: container,
            context: context,
            temporaryDirectory: temporaryDirectory
        )
        let first = makeEpisode(episodeID: "queue-persist-1")
        let second = makeEpisode(episodeID: "queue-persist-2")
        let third = makeEpisode(episodeID: "queue-persist-auto")

        fixture.enqueue(first)
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == first.episodeID
        })
        fixture.enqueue(second)
        fixture.enqueue(third, origin: .auto)
        #expect(await waitUntil {
            (try? context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).count) == 3
        })
        context.insert(AdFreePassQueueItemRecord(
            episodeID: "queue-persist-unresolvable",
            podcastID: "https://example.com/feed.xml",
            originRawValue: "manual",
            sequence: 99
        ))
        try context.save()

        let persisted = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(persisted.count == 4)

        // The first coordinator stays parked until the end: a reset here would let its
        // cancelled pass delete the active record while the restored fixture is built.
        let episodesByID = [first.episodeID: first, second.episodeID: second, third.episodeID: third]
        let restored = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            container: container,
            context: context,
            temporaryDirectory: temporaryDirectory
        )
        restored.coordinator.restorePersistedQueue(
            resolveEpisode: { episodesByID[$0] },
            downloads: restored.downloads,
            transcriptionModels: restored.transcriptionModels,
            appleSpeechAssets: restored.appleSpeechAssets,
            transcriptions: restored.transcriptions,
            adAnalyses: restored.adAnalyses,
            modelContext: context,
            podcastLanguageCode: { _ in nil },
            refreshSkipZones: { _ in 1 }
        )

        // The auto item went to the front, so it holds the lowest sequence.
        #expect(await waitUntil {
            restored.coordinator.queueState == .idle && restored.coordinator.drainOutcomes.count == 3
        })
        #expect(restored.coordinator.drainOutcomes.map(\.episodeID) == [
            third.episodeID, first.episodeID, second.episodeID
        ])
        let remaining = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(remaining.isEmpty)

        fixture.coordinator.reset()
    }

    @Test("Restoring an already loaded queue item preserves one item and its durable record")
    func repeatedRestorationPreservesLoadedItemAndRecord() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(
            downloader: downloader,
            container: container,
            context: context
        )
        let episode = makeEpisode(episodeID: "queue-persist-repeat")
        context.insert(AdFreePassQueueItemRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            originRawValue: AdFreePassQueueOrigin.manual.rawValue,
            sequence: 1
        ))
        try context.save()

        func restore() {
            fixture.coordinator.restorePersistedQueue(
                resolveEpisode: { $0 == episode.episodeID ? episode : nil },
                downloads: fixture.downloads,
                transcriptionModels: fixture.transcriptionModels,
                appleSpeechAssets: fixture.appleSpeechAssets,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses,
                modelContext: context,
                podcastLanguageCode: { _ in nil },
                refreshSkipZones: { _ in 1 }
            )
        }

        restore()
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == episode.episodeID
        })
        restore()

        let inMemoryCount = fixture.coordinator.queueItems.count
            + (fixture.coordinator.activeEpisodeID == nil ? 0 : 1)
        let persisted = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(inMemoryCount == 1)
        #expect(persisted.map(\.episodeID) == [episode.episodeID])

        fixture.coordinator.cancelActivePass()
        fixture.downloads.cancelDownload(episodeID: episode.episodeID, modelContext: context)
    }

    @Test("Interrupted transcription presentation is resumable")
    func interruptedTranscriptionIsResumable() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriber = CompletingEpisodeTranscriber()
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber,
            container: container,
            context: context,
            temporaryDirectory: temporaryDirectory,
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "ad-free-interrupted")

        let downloadRecord = try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: context
        )
        let localFileURL = fixture.downloadFileStore.fileURL(relativePath: try #require(downloadRecord.localRelativePath))
        try insertInterruptedTranscript(
            for: episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            modelSummary: fixture.modelInstaller.summary,
            fileStore: fixture.transcriptFileStore,
            context: context
        )
        await fixture.loadStores()

        #expect(fixture.presentation(for: episode).stage == .interrupted)

        fixture.enqueue(episode, refreshSkipZones: { 1 })

        #expect(await waitUntil {
            fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed
        })
        #expect(transcriber.requestCount == 1)
        #expect(transcriber.lastRequest?.resumeStart == 2)
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)
    }

    @Test("An analysis failure surfaces the card's words as a per-episode failure, never the recorded code")
    func analysisFailureSurfacesMessage() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answer = .failure(.rejected(status: 400), status: 400, listener: .invalidKey)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        let episode = makeEpisode(episodeID: "ad-free-provider-error")
        let expectedMessage = EpisodePipelineState.analysisFailedMessage(for: .providerRejectedKey)

        fixture.enqueue(episode)

        #expect(await waitUntil {
            fixture.coordinator.lastFailureMessage == expectedMessage
        })
        #expect(fixture.presentation(for: episode).stage == .failed(message: expectedMessage))
        #expect(fixture.coordinator.queueState == .idle)
    }

    @Test("An item the listener started that needs a key ends with its reason, the drain goes on, and each one opens the key screen")
    func keyRequiredManualItemsEachPresent() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.route = .keyRequired(.trialExhausted)
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader, analysisEnvironment: analysisEnvironment)
        let first = makeEpisode(episodeID: "key-required-1")
        let second = makeEpisode(episodeID: "key-required-2")
        let third = makeEpisode(episodeID: "key-required-3")
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        #expect(await waitUntil { fixture.coordinator.activeEpisodeID == first.episodeID })
        fixture.enqueue(second)
        fixture.enqueue(third)
        downloader.release(urlContaining: first.episodeID)
        #expect(await waitUntil { fixture.coordinator.drainOutcomes.count == 1 })
        #expect(fixture.coordinator.drainOutcomes[0].kind == .keyRequired(.trialExhausted))
        #expect(fixture.coordinator.queueStatus(for: first.episodeID) == .keyRequired(.trialExhausted))
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.failureKind == .keyRequiredTrialExhausted)
        #expect(presentedReasons == [.trialExhausted])

        // Terminal for that item only: the next manual one presents again in
        // the same drain, and one that finds a route completes.
        analysisEnvironment.route = .keyRequired(.noKey)
        downloader.release(urlContaining: second.episodeID)
        #expect(await waitUntil { fixture.coordinator.drainOutcomes.count == 2 })
        #expect(fixture.coordinator.drainOutcomes[1].kind == .keyRequired(.noKey))
        #expect(presentedReasons == [.trialExhausted, .noKey])
        analysisEnvironment.route = .direct(provider: .google)
        downloader.release(urlContaining: third.episodeID)
        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 3 })
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [first.episodeID, second.episodeID, third.episodeID])
        #expect(fixture.coordinator.drainOutcomes[2].kind == .completed(zoneCount: 1))
        #expect(terminals == [.drained(completedCount: 1, failedCount: 2)])
        #expect(presentedReasons == [.trialExhausted, .noKey])
        // The store never presented on its own; the drain did.
        #expect(analysisEnvironment.presentedReasons.isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)

        let expectedMessage = "Your free analyses are used. Add a key in Settings › AI Services."
        #expect(fixture.presentation(for: first).stage == .failed(message: expectedMessage))
        #expect(fixture.presentation(for: first).primaryActionTitle == "Retry")
    }

    /// A queue of two: the first hands over after Google names the free tier
    /// and ends as `trialEnding` says, and the second must still run.
    private func passOverHandover(
        _ analysisEnvironment: ScriptedAdAnalysisRunEnvironment,
        trialEnding: ScriptedAdAnswer?,
        prepare: (QueueFixture, EpisodeListItemSnapshot) -> Void = { _, _ in }
    ) async throws -> (fixture: QueueFixture, first: EpisodeListItemSnapshot, second: EpisodeListItemSnapshot, presented: () -> [AnalysisKeyRequiredReason]) {
        analysisEnvironment.handoverWindowOpen = true
        analysisEnvironment.googleKeyTier = .notFreeTier
        let refusal = ScriptedAdAnswer.freeTierFailure(.quotaExhausted, listener: .billingOrQuota)
        analysisEnvironment.answerForRun = { run in
            switch run {
            case 1: refusal
            case 2: trialEnding ?? .sponsorRead
            default: .sponsorRead
            }
        }
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }
        let first = makeEpisode(episodeID: "handover-pass-1")
        let second = makeEpisode(episodeID: "handover-pass-2")
        prepare(fixture, first)

        fixture.enqueue(first)
        fixture.enqueue(second)
        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2 })
        return (fixture, first, second, { presentedReasons })
    }

    private func expectDrainWentOn(_ fixture: QueueFixture, past first: EpisodeListItemSnapshot, to second: EpisodeListItemSnapshot) {
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [first.episodeID, second.episodeID])
        #expect(fixture.adAnalyses.record(for: second.episodeID)?.state == .completed)
    }

    @Test(
        "Every ending of a handed-over trial run gives its kind through a pass, with no key screen, and the drain goes on",
        arguments: [
            (AnalysisProviderFailure.trialExhausted, EpisodeAnalysisFailureKind.providerFreeTier),
            (.requestRejected, .generic),
            (.keyRequired, .generic),
        ]
    )
    func handedOverTrialEndingsThroughThePass(listener: AnalysisProviderFailure, kind: EpisodeAnalysisFailureKind) async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.handoverAnswer = .available

        let (fixture, first, second, presented) = try await passOverHandover(
            analysisEnvironment,
            trialEnding: .failure(.rejected(status: 400), status: 400, listener: listener)
        )

        #expect(presented().isEmpty, "\(listener)")
        #expect(analysisEnvironment.presentedReasons.isEmpty, "\(listener)")
        let record = fixture.adAnalyses.record(for: first.episodeID)
        #expect(record?.failureKind == kind, "\(listener)")
        #expect(record?.failureKind?.keyRequiredReason == nil, "\(listener)")
        guard case .failed(let message) = fixture.coordinator.drainOutcomes.first?.kind else {
            Issue.record("the pass did not fail: \(listener)")
            return
        }
        #expect(!message.contains("providerFreeTier"), "\(listener)")
        expectDrainWentOn(fixture, past: first, to: second)
    }

    @Test("A good trial answer whose document cannot be installed ends a pass as generic, with no key screen, and the drain goes on")
    func failedInstallThroughThePass() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.handoverAnswer = .available

        let (fixture, first, second, presented) = try await passOverHandover(analysisEnvironment, trialEnding: nil) { fixture, first in
            // A directory where the document goes. Its path comes from the
            // transcript the pass makes, so it is known once the record is.
            let fileStore = EpisodeAdAnalysisFileStore(baseDirectory: fixture.transcriptFileStore.baseDirectory)
            let adAnalyses = fixture.adAnalyses
            let episodeID = first.episodeID
            analysisEnvironment.onHandover = {
                guard let path = adAnalyses.record(for: episodeID)?.analysisRelativePath else {
                    Issue.record("the episode has no record at the handover")
                    return
                }
                let blocker = fileStore.fileURL(relativePath: path)
                try? FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
                try? Data("blocker".utf8).write(to: blocker.appending(path: "occupied"))
            }
        }

        #expect(presented().isEmpty)
        #expect(analysisEnvironment.presentedReasons.isEmpty)
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.failureKind == .generic)
        // The trial answered and its run stays open, so a later start pays nothing.
        let trial = analysisEnvironment.runs.records(limit: 10).first { $0.route == .trial }
        #expect(trial?.state == .dispatched)
        guard case .failed = fixture.coordinator.drainOutcomes.first?.kind else {
            Issue.record("the pass did not fail")
            return
        }
        expectDrainWentOn(fixture, past: first, to: second)
    }

    @Test("An automatic item that needs a key ends silently, with its reason on the queue")
    func keyRequiredAutoItemNeverPresents() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.route = .keyRequired(.trialExhausted)
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader, analysisEnvironment: analysisEnvironment)
        let first = makeEpisode(episodeID: "key-required-auto-1")
        let second = makeEpisode(episodeID: "key-required-auto-2")
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }

        fixture.enqueue(first, origin: .auto)
        #expect(await waitUntil { fixture.coordinator.activeEpisodeID == first.episodeID })
        fixture.enqueue(second, origin: .auto)
        downloader.release(urlContaining: first.episodeID)
        downloader.release(urlContaining: second.episodeID)
        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2 })

        #expect(presentedReasons.isEmpty)
        #expect(analysisEnvironment.presentedReasons.isEmpty)
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.keyRequired(.trialExhausted), .keyRequired(.trialExhausted)])
        #expect(fixture.coordinator.queueStatus(for: first.episodeID) == .keyRequired(.trialExhausted))
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.failureKind == .keyRequiredTrialExhausted)
        let queue = AdDetectionQueuePresentation(snapshot: fixture.coordinator.queueSnapshot, isBackgroundSessionArmed: false)
        #expect(queue.keyRequiredNotice == AdDetectionQueuePresentation.keyRequiredNotice)

        // The listener's own tap on the same episode presents.
        fixture.enqueue(first)
        #expect(await waitUntil { presentedReasons == [.trialExhausted] })
    }

    @Test("Removing the key in AI Services ends the listener's item at once as needing a key, without the key screen")
    func keyRemovedInAppEndsItemWithoutKeyScreen() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answer = .hold
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader, analysisEnvironment: analysisEnvironment)
        let episode = makeEpisode(episodeID: "key-removed-in-app")
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }

        fixture.enqueue(episode)
        downloader.release(urlContaining: episode.episodeID)
        #expect(await waitUntil { analysisEnvironment.sends.count == 1 })
        #expect(fixture.adAnalyses.activeDirectProvider == .google)
        fixture.adAnalyses.cancelActiveRun(reason: .keyRemoved)

        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1 })
        #expect(fixture.coordinator.drainOutcomes[0].kind == .keyRequired(.noKey))
        #expect(fixture.coordinator.queueStatus(for: episode.episodeID) == .keyRequired(.noKey))
        #expect(fixture.adAnalyses.record(for: episode.episodeID)?.failureKind == .keyRequiredNoKey)
        #expect(fixture.presentation(for: episode).stage == .failed(message: "Add a key in Settings › AI Services to detect ads."))
        #expect(analysisEnvironment.latestRun?.state == .failed)
        #expect(analysisEnvironment.latestRun?.listenerFailure == AnalysisProviderFailure.keyRequired.rawValue)
        #expect(presentedReasons.isEmpty)
        #expect(analysisEnvironment.presentedReasons.isEmpty)

        // The listener's next tap on the episode, still without a key, presents.
        analysisEnvironment.route = .keyRequired(.noKey)
        fixture.enqueue(episode)
        #expect(await waitUntil { presentedReasons == [.noKey] })
    }

    @Test("A restored manual item that needs a key ends silently, and the listener's re-tap presents")
    func keyRequiredRestoredItemNeverPresents() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.route = .keyRequired(.noKey)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment,
            container: container,
            context: context
        )
        let episode = makeEpisode(episodeID: "key-required-restored")
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }
        context.insert(AdFreePassQueueItemRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            originRawValue: AdFreePassQueueOrigin.manual.rawValue,
            sequence: 1
        ))
        try context.save()

        fixture.coordinator.restorePersistedQueue(
            resolveEpisode: { $0 == episode.episodeID ? episode : nil },
            downloads: fixture.downloads,
            transcriptionModels: fixture.transcriptionModels,
            appleSpeechAssets: fixture.appleSpeechAssets,
            transcriptions: fixture.transcriptions,
            adAnalyses: fixture.adAnalyses,
            modelContext: context,
            podcastLanguageCode: { _ in nil },
            refreshSkipZones: { _ in 1 }
        )
        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1 })
        #expect(fixture.coordinator.queueStatus(for: episode.episodeID) == .keyRequired(.noKey))
        #expect(presentedReasons.isEmpty)

        fixture.enqueue(episode)
        #expect(await waitUntil { presentedReasons == [.noKey] })
    }

    @Test("An environmentally resumed item that needs a key ends silently; the listener's next item still presents")
    func keyRequiredEnvironmentalResumeNeverPresents() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.route = .keyRequired(.trialPaused)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: ComputeFailureEpisodeTranscriber(failingRequestCount: 2),
            analysisEnvironment: analysisEnvironment,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            )
        )
        let first = makeEpisode(episodeID: "key-required-environmental-1")
        let second = makeEpisode(episodeID: "key-required-environmental-2")
        // The item whose outcome was just recorded is the one presenting.
        var presentedEpisodeIDs: [String?] = []
        fixture.coordinator.onKeyRequired = { _ in
            presentedEpisodeIDs.append(fixture.coordinator.drainOutcomes.last?.episodeID)
        }

        fixture.enqueue(first)
        fixture.enqueue(second)
        #expect(await waitUntil { fixture.coordinator.isQueuePausedForEnvironmentalInterrupt })
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [first.episodeID, second.episodeID])

        fixture.coordinator.resumeQueueForEnvironmentalAutoResume()
        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2 })
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.keyRequired(.trialPaused), .keyRequired(.trialPaused)])
        // The resumed head was the app's run; the second never started
        // before and is still the listener's.
        #expect(presentedEpisodeIDs == [second.episodeID])
    }

    @Test("Cancelling the pass stops its device run, and a re-tap starts a fresh one")
    func cancelStopsDeviceRun() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answer = .hold
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        let episode = makeEpisode(episodeID: "ad-free-cancel-run")

        fixture.enqueue(episode)
        #expect(await waitUntil { analysisEnvironment.sends.count == 1 })
        #expect(fixture.adAnalyses.isRunning(for: episode.episodeID))

        fixture.coordinator.cancelActivePass()

        // The held send saw the cancellation: the run stopped and its record
        // ended cancelled, not resumable.
        #expect(await waitUntil { !fixture.adAnalyses.hasActiveJob })
        #expect(analysisEnvironment.latestRun?.state == .cancelled)
        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.activeEpisodeID == nil })
        #expect(analysisEnvironment.sends.count == 1)

        // The episode's record stays running until a start moves it on; a
        // re-tap starts a new run instead of waiting on it.
        analysisEnvironment.answer = .sponsorRead
        fixture.enqueue(episode)
        #expect(await waitUntil { fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed })
        #expect(analysisEnvironment.resolvedRunIDs.count == 2)
    }

    @Test("A card expiry stops the device run and keeps it resumable")
    func expiryStopsDeviceRunResumably() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answer = .hold
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()
        fixture.coordinator.onStageChange = { stage, context in session.noteStage(stage, queueContext: context) }
        let episode = makeEpisode(episodeID: "ad-free-expire-run")

        fixture.enqueue(episode)
        session.arm(episodeTitle: episode.title, cancellationSource: fixture.coordinator.cancellationSource)
        scheduler.launch(handle)
        #expect(await waitUntil { analysisEnvironment.sends.count == 1 })

        handle.expire()

        #expect(await waitUntil { !fixture.adAnalyses.hasActiveJob })
        #expect(analysisEnvironment.latestRun?.state == .expired)
        #expect(await waitUntil { fixture.coordinator.activeEpisodeID == nil })
        #expect(handle.completions == [false])
    }

    @Test("A window whose answer fails validation holds the pass below the band's end while its repair is slow")
    func slowRepairHoldsBelowTheBandEnd() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answerForRequest = { request in
            request.purpose == .adRepair(index: 0) ? .hold : .unverifiableBreak
        }
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler, now: { currentDate })
        let handle = FakeAdFreePassContinuedTaskHandle()
        fixture.coordinator.onStageChange = { stage, context in session.noteStage(stage, queueContext: context) }
        let episode = makeEpisode(episodeID: "ad-free-slow-repair")

        fixture.enqueue(episode)
        session.arm(episodeTitle: episode.title, cancellationSource: fixture.coordinator.cancellationSource)
        scheduler.launch(handle)
        defer { session.reset() }
        #expect(await waitUntil { analysisEnvironment.sends.count(of: .adRepair(index: 0)) == 1 })

        // The window's reply counted it answered; the repair is still out.
        let attemptID = try #require(analysisEnvironment.latestRun).id
        let repairing = EpisodeAdFreePassStage.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 2, attemptID: attemptID))
        #expect(await waitUntil { fixture.coordinator.currentStage == repairing })
        #expect(fixture.coordinator.queueSnapshot.fractionCompleted == 0.942)
        #expect(await waitUntil { handle.adFreeUnits == 942 })
        // Halfway through the repair's budget the card has moved; long past
        // it, the card waits one unit short of the band's end.
        currentDate += AdAnalysisRunProgress.defaultStepBudgetSeconds / 2
        #expect(await waitUntil { handle.adFreeUnits == 958 })
        currentDate += 3_600
        #expect(await waitUntil { handle.adFreeUnits == 974 })
        #expect(handle.adFreeUnits < 975)
        #expect(fixture.adAnalyses.isRunning(for: episode.episodeID))

        fixture.coordinator.cancelActivePass()
        #expect(await waitUntil { !fixture.adAnalyses.hasActiveJob })
    }

    @Test("The listener's Resume of an automatic item paused in the background makes it theirs: a key-required end opens the key screen")
    func listenerResumeOfAutomaticItemPresents() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.route = .keyRequired(.trialExhausted)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: ComputeFailureEpisodeTranscriber(failingRequestCount: 2),
            analysisEnvironment: analysisEnvironment,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            )
        )
        let episode = makeEpisode(episodeID: "key-required-auto-resumed")
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }

        fixture.enqueue(episode, origin: .auto)
        #expect(await waitUntil { fixture.coordinator.isQueuePausedForEnvironmentalInterrupt })
        #expect(fixture.coordinator.queueItems.first?.origin == .auto)

        fixture.coordinator.resumePausedQueue()

        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1 })
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.keyRequired(.trialExhausted)])
        #expect(presentedReasons == [.trialExhausted])
    }

    @Test("Completed transcript is reused by the default path without re-transcribing or re-analyzing")
    func completedTranscriptIsReusedByDefaultPath() async throws {
        let transcriber = CompletingEpisodeTranscriber()
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber
        )
        let episode = makeEpisode(episodeID: "ad-free-reuse-default")
        var refreshCount = 0

        fixture.enqueue(episode, refreshSkipZones: {
            refreshCount += 1
            return 1
        })
        #expect(await waitUntil {
            refreshCount == 1 && fixture.coordinator.activeEpisodeID == nil
        })
        #expect(transcriber.requestCount == 1)
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)

        fixture.enqueue(episode, refreshSkipZones: {
            refreshCount += 1
            return 1
        })
        #expect(await waitUntil {
            refreshCount == 2 && fixture.coordinator.activeEpisodeID == nil
        })

        #expect(transcriber.requestCount == 1)
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)
    }

    @Test("A pass resumes a paused download once and completes")
    func passResumesPausedDownloadAndCompletes() async throws {
        let contents = Data("downloaded audio".utf8)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: contents),
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-resume-paused")
        try insertPausedDownload(for: episode, partial: Data("part".utf8), fixture: fixture)
        await fixture.loadStores()

        guard case .failed(message: let pausedMessage) = fixture.presentation(for: episode).stage else {
            Issue.record("Expected paused download presentation to fail with an actionable message.")
            return
        }
        #expect(pausedMessage == "Download paused.")

        fixture.enqueue(episode)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle
                && fixture.coordinator.activeEpisodeID == nil
                && fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed
        })
        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .completed)
        #expect(fixture.coordinator.drainFailedCount == 0)
    }

    @Test(
        "A completed download whose file is gone or drifted downloads once more and the pass completes over the new file",
        arguments: DownloadFileDefect.allCases
    )
    func defectiveDownloadedFileDownloadsOnceMoreAndCompletes(defect: DownloadFileDefect) async throws {
        let redownloaded = Data("downloaded audio".utf8)
        let downloader = ScriptedEpisodeAudioDownloader(contents: redownloaded)
        let fixture = try await makeFixture(downloader: downloader, loadsStores: false)
        let episode = makeEpisode(episodeID: "pass-defective-file-\(defect)")
        let record = try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            isHashed: defect != .driftedUnhashed
        )
        await fixture.loadStores()
        // After load (reconcile sees the file), the file changes — the
        // delete-races-a-job case reconcile cannot catch.
        try defect.apply(to: fixture.downloadFileStore.fileURL(relativePath: try #require(record.localRelativePath)))

        fixture.enqueue(episode)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(downloader.requestCount == 1)
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 == OpenCastSHA256.hash(redownloaded))
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(redownloaded))
    }

    @Test("A download that is untrusted again after its one re-download fails the pass and marks the record missing")
    func untrustedRedownloadFailsPass() async throws {
        let downloader = ScriptedEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        let fixture = try await makeFixture(downloader: downloader, loadsStores: false)
        let episode = makeEpisode(episodeID: "pass-untrusted-twice")
        let record = try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            isHashed: true
        )
        await fixture.loadStores()
        let fileURL = fixture.downloadFileStore.fileURL(relativePath: try #require(record.localRelativePath))
        try DownloadFileDefect.drifted.apply(to: fileURL)
        fixture.downloads.onDownloadCompleted = { _, _ in
            try? DownloadFileDefect.drifted.apply(to: fileURL)
        }

        fixture.enqueue(episode)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [
            .failed(message: EpisodeDownloadError.missingDownloadedFile.localizedDescription),
        ])
        #expect(downloader.requestCount == 1)
        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .missing)
        #expect(fixture.transcriptions.record(for: episode.episodeID) == nil)
    }

    @Test(
        "An unhashed download of its recorded size adopts its hash, then reuses a transcript of those bytes or transcribes it again",
        arguments: [true, false]
    )
    func unhashedDownloadAdoptsHashThenReusesOrTranscribes(transcriptMatches: Bool) async throws {
        let transcriber = CompletingEpisodeTranscriber()
        let downloader = ScriptedEpisodeAudioDownloader(contents: nil)
        let fixture = try await makeFixture(downloader: downloader, transcriber: transcriber, loadsStores: false)
        let episode = makeEpisode(episodeID: "pass-adopt-\(transcriptMatches)")
        let contents = Data("an unhashed download".utf8)
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            contents: contents
        )
        let priorPath = try insertCompletedTranscript(
            for: episode,
            sourceSHA256: transcriptMatches ? OpenCastSHA256.hash(contents) : OpenCastSHA256.hash(Data("other bytes".utf8)),
            byteCount: Int64(contents.count),
            fixture: fixture
        )
        await fixture.loadStores()
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID) == nil)

        fixture.enqueue(episode)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(downloader.requestCount == 0)
        #expect(fixture.downloads.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(contents))
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 == OpenCastSHA256.hash(contents))
        #expect(transcriber.requestCount == (transcriptMatches ? 0 : 1))
        let transcript = try #require(fixture.transcriptions.record(for: episode.episodeID))
        #expect(transcript.sourceFileSHA256 == OpenCastSHA256.hash(contents))
        #expect((transcript.transcriptRelativePath == priorPath) == transcriptMatches)
        #expect(fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed)
    }

    @Test("A completed transcript of other bytes is transcribed again and replaces the transcript and analysis documents")
    func detachedTranscriptIsTranscribedAgainAndReplacesDocuments() async throws {
        let transcriber = CompletingEpisodeTranscriber()
        let first = Data("the first assembly".utf8)
        let second = Data("a different assembly".utf8)
        let downloader = ScriptedEpisodeAudioDownloader(contents: first)
        let fixture = try await makeFixture(downloader: downloader, transcriber: transcriber)
        let episode = makeEpisode(episodeID: "pass-retranscribe")
        let replaced = try await passOverReplacedDownload(
            episode,
            fixture: fixture,
            downloader: downloader,
            first: first,
            second: second
        )

        #expect(transcriber.requestCount == 2)
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 2)
        #expect(try fixture.transcriptRecordCount(for: episode.episodeID) == 1)
        let transcript = try #require(fixture.transcriptions.record(for: episode.episodeID))
        #expect(transcript.state == .completed)
        #expect(transcript.sourceFileSHA256 == OpenCastSHA256.hash(second))
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 == OpenCastSHA256.hash(second))
        #expect(replaced.after.sourceFileSHA256 == OpenCastSHA256.hash(second))
        #expect(replaced.before.sourceFileSHA256 == OpenCastSHA256.hash(first))
        #expect(replaced.transcriptPaths.before != replaced.transcriptPaths.after)
        #expect(!fixture.transcriptFileStore.documentExists(relativePath: replaced.transcriptPaths.before))
        #expect(fixture.transcriptFileStore.documentExists(relativePath: replaced.transcriptPaths.after))
        #expect(replaced.analysisPaths.before != replaced.analysisPaths.after)
        #expect(!fixture.adAnalysisFileStore.documentExists(relativePath: replaced.analysisPaths.before))
        #expect(fixture.adAnalysisFileStore.documentExists(relativePath: replaced.analysisPaths.after))
        #expect(await fixture.adAnalyses.hasCurrentCompletedAnalysis(for: replaced.after))
    }

    @Test(
        "A cancelled or a failed replacement fails the pass and restores the prior transcript",
        arguments: ReplacementEnding.allCases
    )
    func stoppedReplacementRestoresPriorTranscript(ending: ReplacementEnding) async throws {
        let transcriber = HoldingEpisodeTranscriber()
        let fixture = try await makeFixture(downloader: ScriptedEpisodeAudioDownloader(contents: nil), transcriber: transcriber, loadsStores: false)
        let episode = makeEpisode(episodeID: "pass-replacement-\(ending)")
        let priorPath = try await seedDetachedTranscript(for: episode, contents: Data("current audio".utf8), fixture: fixture)
        let prior = try #require(fixture.transcriptions.record(for: episode.episodeID)?.sourceFileSHA256)

        fixture.enqueue(episode)
        #expect(await waitUntil { transcriber.requestCount == 1 })
        switch ending {
        case .cancelled:
            fixture.transcriptions.cancelTranscription(episodeID: episode.episodeID, modelContext: fixture.context)
        case .failed:
            transcriber.fail(with: ReplacementEnding.Failure())
        }

        #expect(await fixture.waitForDrain())
        let message = ending == .failed
            ? ReplacementEnding.Failure().localizedDescription
            : "Transcript cancelled."
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.failed(message: message)])
        let transcript = try #require(fixture.transcriptions.record(for: episode.episodeID))
        #expect(transcript.state == .completed)
        #expect(transcript.sourceFileSHA256 == prior)
        #expect(transcript.transcriptRelativePath == priorPath)
        #expect(fixture.transcriptFileStore.documentExists(relativePath: priorPath))
        #expect(fixture.transcriptions.interruptedReplacement(for: episode.episodeID) == nil)
    }

    @Test("An interrupted replacement ends its item as interrupted, not failed, and keeps the prior transcript")
    func interruptedReplacementEndsAsInterrupted() async throws {
        let transcriber = HoldingEpisodeTranscriber()
        let fixture = try await makeFixture(downloader: ScriptedEpisodeAudioDownloader(contents: nil), transcriber: transcriber, loadsStores: false)
        let episode = makeEpisode(episodeID: "pass-replacement-interrupted")
        let priorPath = try await seedDetachedTranscript(for: episode, contents: Data("current audio".utf8), fixture: fixture)
        var stages: [EpisodeAdFreePassStage] = []
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onStageChange = { stage, _ in stages.append(stage) }
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(episode)
        #expect(await waitUntil { transcriber.requestCount == 1 })
        fixture.transcriptions.interruptActiveJob(modelContext: fixture.context)

        #expect(await waitUntil { !terminals.isEmpty && fixture.coordinator.activeEpisodeID == nil })
        #expect(terminals == [.interrupted])
        #expect(stages.last == .interrupted)
        #expect(fixture.coordinator.drainOutcomes.isEmpty)
        #expect(fixture.coordinator.lastFailureMessage == nil)
        // A lifecycle stop drops the item, as for a first transcription.
        #expect(fixture.coordinator.queueItems.isEmpty)
        #expect(!fixture.coordinator.isQueuePausedForEnvironmentalInterrupt)
        // The pass read the note once.
        #expect(fixture.transcriptions.interruptedReplacement(for: episode.episodeID) == nil)
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.state == .completed)
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.transcriptRelativePath == priorPath)
    }

    @Test("An environmental stop of a replacement pauses the drain with the item held, and the auto-resume completes it")
    func environmentalReplacementStopPausesAndResumes() async throws {
        let transcriber = ComputeFailureEpisodeTranscriber(failingRequestCount: 2)
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            ),
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-replacement-environmental")
        let contents = Data("current audio".utf8)
        let priorPath = try await seedDetachedTranscript(for: episode, contents: contents, fixture: fixture)

        fixture.enqueue(episode)

        #expect(await waitUntil { fixture.coordinator.queueState == .pausedInterrupted })
        #expect(fixture.coordinator.isQueuePausedForEnvironmentalInterrupt)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [episode.episodeID])
        #expect(fixture.coordinator.drainOutcomes.isEmpty)
        #expect(fixture.transcriptions.interruptedReplacement(for: episode.episodeID) == nil)
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.transcriptRelativePath == priorPath)

        fixture.coordinator.resumeQueueForEnvironmentalAutoResume()

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(contents))
        #expect(!fixture.transcriptFileStore.documentExists(relativePath: priorPath))
        #expect(fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed)
    }

    @Test("The automatic launch skip holds only while the current analysis is attached to the download")
    func automaticLaunchSkipHonoursAttachment() async throws {
        let downloader = ScriptedEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        let fixture = try await makeFixture(downloader: downloader)
        let episode = makeEpisode(episodeID: "pass-auto-skip-attachment")
        fixture.enqueue(episode)
        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(await waitUntil {
            fixture.coordinator.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses
            )
        })

        // Attached: the automatic item is skipped before it records anything.
        fixture.enqueue(episode, origin: .auto)
        #expect(await waitUntil { fixture.coordinator.queueItems.isEmpty && fixture.coordinator.queueState == .idle })
        #expect(fixture.coordinator.drainOutcomes.isEmpty)
        #expect(downloader.requestCount == 1)

        // Detached by the download's removal: the same item runs.
        let download = try #require(fixture.downloads.record(for: episode.episodeID))
        fixture.downloads.deleteDownload(download, modelContext: fixture.context)
        fixture.enqueue(episode, origin: .auto)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(downloader.requestCount == 2)
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID) != nil)
    }

    @Test("A current analysis without its trusted download presents Detect Ads Again, after active work and the download states")
    func detachedPresentationFollowsActiveWorkAndDownloadStates() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let episode = makeEpisode(episodeID: "presentation-detached")
        let holder = makeEpisode(episodeID: "presentation-holder")
        downloader.release(urlContaining: episode.episodeID)
        fixture.enqueue(episode)
        #expect(await fixture.waitForDrain())
        #expect(await waitUntil {
            fixture.presentation(for: episode).stage == .completed(zoneCount: 0)
        })

        // The file goes while its record still reads completed.
        let download = try #require(fixture.downloads.record(for: episode.episodeID))
        let fileURL = try #require(fixture.downloads.localFileURL(for: download))
        try FileManager.default.removeItem(at: fileURL)
        let detached = fixture.presentation(for: episode)
        #expect(detached == .detached)
        #expect(detached.primaryActionTitle == "Detect Ads Again")
        #expect(detached.isPrimaryActionEnabled)
        #expect(detached.stage == .idle)
        #expect(detached.statusText == EpisodeAdSpanTimelineView.detachedCaption)

        // A download state comes first.
        try fixture.downloads.markDownloadedFileMissing(download, modelContext: fixture.context)
        #expect(fixture.presentation(for: episode).stage
            == .failed(message: EpisodeDownloadError.missingDownloadedFile.localizedDescription))

        // With no download at all, the analysis presents detached again.
        fixture.downloads.deleteDownload(download, modelContext: fixture.context)
        #expect(fixture.presentation(for: episode) == .detached)

        // Active work comes first: the episode waits behind another pass.
        fixture.enqueue(holder)
        #expect(await waitUntil { fixture.coordinator.activeEpisodeID == holder.episodeID })
        fixture.enqueue(episode)
        #expect(fixture.presentation(for: episode) == .queued(ahead: 1))

        await fixture.coordinator.removePendingItem(episodeID: episode.episodeID, modelContext: fixture.context)?.value
        #expect(fixture.presentation(for: episode) == .detached)
        downloader.release(urlContaining: holder.episodeID)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.activeEpisodeID == nil
        })
    }

    @Test("A retained replay failure blocks an automatic pass over the same transcript, and a transcript of new bytes escapes it")
    func replaySuppressionHoldsForIdenticalInputsOnly() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answer = .unverifiableBreak
        let first = Data("the first assembly".utf8)
        let downloader = ScriptedEpisodeAudioDownloader(contents: first)
        let fixture = try await makeFixture(downloader: downloader, analysisEnvironment: analysisEnvironment)
        let episode = makeEpisode(episodeID: "pass-replay-suppression")

        fixture.enqueue(episode)
        #expect(await fixture.waitForDrain())
        #expect(fixture.adAnalyses.record(for: episode.episodeID)?.failureKind == .validationExhausted)
        let sendsAfterFailure = analysisEnvironment.sends.count

        // Identical transcript, identical inputs: the suppression holds.
        fixture.enqueue(episode, origin: .auto)
        #expect(await fixture.waitForDrain())
        guard case .failed = fixture.coordinator.drainOutcomes.first?.kind else {
            Issue.record("Expected the suppressed automatic pass to fail.")
            return
        }
        #expect(analysisEnvironment.sends.count == sendsAfterFailure)

        // New bytes, so a new transcript: the suppression no longer applies.
        analysisEnvironment.answer = .sponsorRead
        let download = try #require(fixture.downloads.record(for: episode.episodeID))
        fixture.downloads.deleteDownload(download, modelContext: fixture.context)
        downloader.contents = Data("a different assembly".utf8)
        fixture.enqueue(episode, origin: .auto)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(analysisEnvironment.sends.count > sendsAfterFailure)
        #expect(fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed)
    }

    @Test(
        "A cloud pass reuses a completed transcript only over a trusted download of its bytes",
        arguments: [true, false]
    )
    func cloudPassReusesOnlyOverTrustedDownload(hasTrustedDownload: Bool) async throws {
        let contents = Data("cloud episode audio".utf8)
        let downloader = ScriptedEpisodeAudioDownloader(contents: contents)
        let fixture = try await makeFixture(downloader: downloader, loadsStores: false)
        let episode = makeEpisode(episodeID: "cloud-reuse-\(hasTrustedDownload)")
        if hasTrustedDownload {
            try insertCompletedDownload(
                for: episode,
                fileStore: fixture.downloadFileStore,
                context: fixture.context,
                contents: contents,
                isHashed: true
            )
        }
        // The same transcript either way: only the download differs.
        try insertCompletedTranscript(
            for: episode,
            sourceSHA256: OpenCastSHA256.hash(contents),
            byteCount: Int64(contents.count),
            fixture: fixture
        )
        await fixture.loadStores()
        let rig = try makeCloudRig(for: fixture, delivering: contents)

        fixture.enqueueCloud(episode, rig: rig)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 0)])
        #expect(rig.api.createRequests.count == (hasTrustedDownload ? 0 : 1))
        #expect(downloader.requestCount == (hasTrustedDownload ? 0 : 1))
        let transcript = try #require(fixture.transcriptions.record(for: episode.episodeID))
        #expect(transcript.engineProvenance == (hasTrustedDownload ? .localWhisper : .remoteWhisper))
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 == transcript.sourceFileSHA256)
        #expect(fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed)
    }

    @Test("A cloud job over an unhashed download leaves the download hashed and trusted, attached to the delivered transcript")
    func cloudJobOverUnhashedDownloadAdoptsHash() async throws {
        let contents = Data("an unhashed cloud download".utf8)
        let downloader = ScriptedEpisodeAudioDownloader(contents: nil)
        let fixture = try await makeFixture(downloader: downloader, loadsStores: false)
        let episode = makeEpisode(episodeID: "cloud-adopt")
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            contents: contents
        )
        await fixture.loadStores()
        let rig = try makeCloudRig(for: fixture, delivering: contents)

        fixture.enqueueCloud(episode, rig: rig)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 0)])
        #expect(rig.api.createRequests.map(\.sourceIdentity) == [nil])
        #expect(rig.api.reportedIdentities.map(\.sha256) == [OpenCastSHA256.hash(contents)])
        #expect(downloader.requestCount == 0)
        #expect(fixture.downloads.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(contents))
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 == OpenCastSHA256.hash(contents))
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(contents))
    }

    @Test(
        "A download replaced while a pass loads a transcript of its old bytes is transcribed again, not analysed over that transcript",
        arguments: TranscriptLoadSite.allCases
    )
    func downloadReplacedDuringTranscriptLoadIsTranscribedAgain(site: TranscriptLoadSite) async throws {
        let first = Data("the first assembly".utf8)
        let second = Data("a different assembly".utf8)
        let transcriber = CompletingEpisodeTranscriber()
        let transcriptReads = TranscriptReadInterceptor()
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false,
            transcriptReads: transcriptReads
        )
        let episode = makeEpisode(episodeID: "pass-replaced-during-load-\(site)")
        let firstTranscriptPath = try seedAttachedTranscript(for: episode, contents: first, fixture: fixture)
        await fixture.loadStores()
        let rig = site == .cloudReuse ? try makeCloudRig(for: fixture, delivering: second) : nil
        transcriptReads.once { relativePath in
            guard relativePath == firstTranscriptPath else {
                return false
            }
            replaceDownloadedBytes(for: episode, with: second, fixture: fixture)
            return true
        }

        enqueue(episode, at: site, rig: rig, fixture: fixture)

        #expect(await fixture.waitForDrain())
        #expect(transcriptReads.actionCount == 1)
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: site == .cloudReuse ? 0 : 1)])
        #expect(transcriber.requestCount == (site == .cloudReuse ? 0 : 1))
        #expect((rig?.api.createRequests.count ?? 0) == (site == .cloudReuse ? 1 : 0))
        let transcript = try #require(fixture.transcriptions.document(for: episode.episodeID))
        #expect(transcript.sourceFileSHA256 == OpenCastSHA256.hash(second))
        #expect(fixture.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 == OpenCastSHA256.hash(second))
        #expect(await fixture.adAnalyses.hasCurrentCompletedAnalysis(for: transcript))
    }

    @Test(
        "A download removed while a pass loads a transcript of its bytes never has that transcript analysed",
        arguments: TranscriptLoadSite.allCases
    )
    func downloadRemovedDuringTranscriptLoadIsNotAnalysedOverIt(site: TranscriptLoadSite) async throws {
        let scanned = Data("the scanned assembly".utf8)
        let redownloaded = Data("a later assembly".utf8)
        let transcriber = CompletingEpisodeTranscriber()
        let transcriptReads = TranscriptReadInterceptor()
        let downloader = ScriptedEpisodeAudioDownloader(contents: redownloaded)
        let fixture = try await makeFixture(
            downloader: downloader,
            transcriber: transcriber,
            loadsStores: false,
            transcriptReads: transcriptReads
        )
        let episode = makeEpisode(episodeID: "pass-removed-during-load-\(site)")
        let scannedTranscriptPath = try seedAttachedTranscript(for: episode, contents: scanned, fixture: fixture)
        await fixture.loadStores()
        let rig = site == .cloudReuse ? try makeCloudRig(for: fixture, delivering: redownloaded) : nil
        transcriptReads.once { relativePath in
            guard relativePath == scannedTranscriptPath,
                  let download = fixture.downloads.record(for: episode.episodeID)
            else {
                return false
            }
            fixture.downloads.deleteDownload(download, modelContext: fixture.context)
            return true
        }

        enqueue(episode, at: site, rig: rig, fixture: fixture)

        #expect(await fixture.waitForDrain())
        #expect(transcriptReads.actionCount == 1)
        switch site {
        case .reuse, .jobState:
            // The download the pass had is gone; it never analyses the
            // transcript of those bytes.
            #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [
                .failed(message: EpisodeTranscriptionError.downloadNotComplete.localizedDescription),
            ])
            #expect(transcriber.requestCount == 0)
            #expect(downloader.requestCount == 0)
            #expect(fixture.adAnalyses.record(for: episode.episodeID) == nil)
        case .cloudReuse:
            // The job downloads the episode again and transcribes those bytes.
            #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 0)])
            #expect(downloader.requestCount == 1)
            #expect(rig?.api.createRequests.count == 1)
            #expect(fixture.transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(redownloaded))
        }
    }

    @Test("A download replaced while a pass loads the transcript it just made ends the pass instead of transcribing again")
    func downloadReplacedDuringOwnTranscriptLoadEndsThePass() async throws {
        let first = Data("the first assembly".utf8)
        let transcriber = CompletingEpisodeTranscriber()
        let transcriptReads = TranscriptReadInterceptor()
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false,
            transcriptReads: transcriptReads
        )
        let episode = makeEpisode(episodeID: "pass-replaced-during-own-load")
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            contents: first,
            isHashed: true
        )
        await fixture.loadStores()
        transcriptReads.once { _ in
            // The pass's own transcript has committed and is being read.
            guard fixture.transcriptions.record(for: episode.episodeID)?.state == .completed else {
                return false
            }
            replaceDownloadedBytes(for: episode, with: Data("a different assembly".utf8), fixture: fixture)
            return true
        }

        fixture.enqueue(episode)

        #expect(await fixture.waitForDrain())
        #expect(transcriptReads.actionCount == 1)
        // A pass transcribes once: the second time it finds the episode
        // still to transcribe, it ends.
        #expect(transcriber.requestCount == 1)
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.failed(message: "Transcript failed.")])
        #expect(fixture.adAnalyses.record(for: episode.episodeID) == nil)
    }

    @Test(
        "A transcript document of other bytes than its record, over a download that holds still, fails the pass instead of going round",
        arguments: [TranscriptLoadSite.reuse, .jobState]
    )
    func documentDisagreeingWithItsRecordFailsThePass(site: TranscriptLoadSite) async throws {
        let contents = Data("the scanned assembly".utf8)
        let transcriber = CompletingEpisodeTranscriber()
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-document-disagrees-\(site)")
        let transcriptPath = try seedAttachedTranscript(for: episode, contents: contents, fixture: fixture)
        await fixture.loadStores()
        // The record still names the download's bytes; its document names
        // others.
        var document = try fixture.transcriptFileStore.read(relativePath: transcriptPath)
        document.sourceFileSHA256 = OpenCastSHA256.hash(Data("other bytes".utf8))
        try fixture.transcriptFileStore.write(document, relativePath: transcriptPath)

        enqueue(episode, at: site, rig: nil, fixture: fixture)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [
            .failed(message: EpisodeTranscriptionError.transcriptDocumentMissing.localizedDescription),
        ])
        #expect(transcriber.requestCount == 0)
        #expect(fixture.adAnalyses.record(for: episode.episodeID) == nil)
    }

    @Test("A download whose file cannot be read fails the pass with the read error, without downloading it again")
    func unreadableDownloadFailsPassWithoutRedownload() async throws {
        let contents = Data("an unreadable download".utf8)
        let downloader = ScriptedEpisodeAudioDownloader(contents: contents)
        let fixture = try await makeFixture(downloader: downloader, loadsStores: false)
        let episode = makeEpisode(episodeID: "pass-unreadable-download")
        let record = try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            contents: contents
        )
        await fixture.loadStores()
        let fileURL = fixture.downloadFileStore.fileURL(relativePath: try #require(record.localRelativePath))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }
        // The file is there, at its recorded size, and cannot be read.
        let readError = #expect(throws: (any Error).self) {
            _ = try FileHandle(forReadingFrom: fileURL)
        }
        let readFailure = try #require(readError).localizedDescription

        fixture.enqueue(episode)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.failed(message: readFailure)])
        #expect(downloader.requestCount == 0)
        let download = try #require(fixture.downloads.record(for: episode.episodeID))
        #expect(download.state == .completed)
        #expect(download.sourceFileSHA256.isEmpty)
        #expect(fixture.transcriptions.record(for: episode.episodeID) == nil)
    }

    private func enqueue(
        _ episode: EpisodeListItemSnapshot,
        at site: TranscriptLoadSite,
        rig: CloudRig?,
        fixture: QueueFixture
    ) {
        switch site {
        case .reuse:
            fixture.enqueue(episode)
        case .jobState:
            fixture.enqueue(episode, engine: .whisperTiny)
        case .cloudReuse:
            guard let rig else {
                Issue.record("A cloud pass needs a rig.")
                return
            }
            fixture.enqueueCloud(episode, rig: rig)
        }
    }

    /// A hashed download of `contents` and a completed transcript of those
    /// bytes, made by the installed model; returns the transcript's path.
    private func seedAttachedTranscript(
        for episode: EpisodeListItemSnapshot,
        contents: Data,
        fixture: QueueFixture
    ) throws -> String {
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            contents: contents,
            isHashed: true
        )
        return try insertCompletedTranscript(
            for: episode,
            sourceSHA256: OpenCastSHA256.hash(contents),
            byteCount: Int64(contents.count),
            fixture: fixture
        )
    }

    /// A re-download of the episode that landed other bytes: its record and
    /// file now hold `contents`, hashed as a completed download is.
    private func replaceDownloadedBytes(
        for episode: EpisodeListItemSnapshot,
        with contents: Data,
        fixture: QueueFixture
    ) {
        guard let record = fixture.downloads.record(for: episode.episodeID),
              let fileURL = fixture.downloads.localFileURL(for: record)
        else {
            Issue.record("Expected a completed download to replace.")
            return
        }
        do {
            try contents.write(to: fileURL, options: .atomic)
            record.bytesReceived = Int64(contents.count)
            record.bytesExpected = Int64(contents.count)
            record.sourceFileSHA256 = OpenCastSHA256.hash(contents)
            try fixture.context.save()
        } catch {
            Issue.record(error)
        }
    }

    /// One pass over `first`, then the download's removal and a pass over
    /// `second`; the transcripts and document paths before and after.
    private func passOverReplacedDownload(
        _ episode: EpisodeListItemSnapshot,
        fixture: QueueFixture,
        downloader: ScriptedEpisodeAudioDownloader,
        first: Data,
        second: Data
    ) async throws -> ReplacedTranscript {
        fixture.enqueue(episode)
        #expect(await fixture.waitForDrain())
        let before = try #require(fixture.transcriptions.document(for: episode.episodeID))
        #expect(before.sourceFileSHA256 == OpenCastSHA256.hash(first))
        let transcriptBefore = try #require(fixture.transcriptions.record(for: episode.episodeID)?.transcriptRelativePath)
        let analysisBefore = try #require(fixture.adAnalyses.record(for: episode.episodeID)?.analysisRelativePath)
        #expect(fixture.adAnalysisFileStore.documentExists(relativePath: analysisBefore))

        let download = try #require(fixture.downloads.record(for: episode.episodeID))
        fixture.downloads.deleteDownload(download, modelContext: fixture.context)
        downloader.contents = second
        fixture.enqueue(episode)
        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])

        let after = try #require(fixture.transcriptions.document(for: episode.episodeID))
        let transcriptAfter = try #require(fixture.transcriptions.record(for: episode.episodeID)?.transcriptRelativePath)
        let analysisAfter = try #require(fixture.adAnalyses.record(for: episode.episodeID)?.analysisRelativePath)
        return ReplacedTranscript(
            before: before,
            after: after,
            transcriptPaths: (transcriptBefore, transcriptAfter),
            analysisPaths: (analysisBefore, analysisAfter)
        )
    }

    private struct ReplacedTranscript {
        let before: EpisodeTranscriptDocument
        let after: EpisodeTranscriptDocument
        let transcriptPaths: (before: String, after: String)
        let analysisPaths: (before: String, after: String)
    }

    @Test("Pausing again while a pass waits fails that item and drains the queue")
    func repausingDuringPassFailsItemAndDrains() async throws {
        let fixture = try await makeFixture(
            downloader: HangingEpisodeAudioDownloader(),
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-repause")
        try insertPausedDownload(for: episode, partial: Data("part".utf8), fixture: fixture)
        await fixture.loadStores()

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.downloads.record(for: episode.episodeID)?.state == .downloading
                && fixture.downloads.byteProgress(for: episode.episodeID)?.bytesReceived == 7
        })

        fixture.downloads.pauseDownload(episodeID: episode.episodeID, modelContext: fixture.context)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle
                && fixture.coordinator.activeEpisodeID == nil
                && fixture.coordinator.drainOutcomes.count == 1
        })
        let outcome = try #require(fixture.coordinator.drainOutcomes.first)
        guard case .failed(message: let message) = outcome.kind else {
            Issue.record("Expected the re-paused pass item to fail.")
            return
        }
        #expect(message == "Download paused.")
        #expect(fixture.coordinator.drainFailedCount == 1)
    }

    @Test("removePendingItem removes a queued item, keeps the active pass, and drops the persisted record")
    func removePendingItemRemovesQueuedItemOnly() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let first = makeEpisode(episodeID: "remove-pending-1")
        let second = makeEpisode(episodeID: "remove-pending-2")
        let third = makeEpisode(episodeID: "remove-pending-3")

        fixture.enqueue(first)
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == first.episodeID
        })
        fixture.enqueue(second)
        fixture.enqueue(third)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [second.episodeID, third.episodeID])
        #expect(await waitUntil {
            let episodeIDs = try? fixture.context.fetch(
                FetchDescriptor<AdFreePassQueueItemRecord>()
            ).map(\.episodeID)
            return episodeIDs?.contains(third.episodeID) == true
        })

        fixture.coordinator.removePendingItem(episodeID: first.episodeID, modelContext: fixture.context)
        #expect(fixture.coordinator.activeEpisodeID == first.episodeID)

        fixture.coordinator.removePendingItem(episodeID: second.episodeID, modelContext: fixture.context)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [third.episodeID])
        #expect(fixture.coordinator.queueStatus(for: second.episodeID) == .notQueued)
        #expect(fixture.coordinator.queueStatus(for: third.episodeID) == .queued(ahead: 1))
        #expect(fixture.coordinator.queueState == .running)
        let records = try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(records.map(\.episodeID).sorted() == [first.episodeID, third.episodeID].sorted())

        downloader.release(urlContaining: first.episodeID)
        downloader.release(urlContaining: third.episodeID)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.activeEpisodeID == nil
        })
    }

    @Test("Removing the last pending item returns a consent-paused queue to idle and clears consent state")
    func removePendingItemNormalizesPausedQueue() async throws {
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            modelInstalled: false
        )
        let episode = makeEpisode(episodeID: "remove-pending-consent")

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .awaitingModelConsent
        })

        fixture.coordinator.removePendingItem(episodeID: episode.episodeID, modelContext: fixture.context)

        #expect(fixture.coordinator.queueItems.isEmpty)
        #expect(fixture.coordinator.queueState == .idle)
        #expect(fixture.coordinator.pendingModelConsentEpisodeID == nil)
        #expect(fixture.coordinator.pendingModelConsentByteCount == nil)
        let records = try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(records.isEmpty)
    }

    // MARK: - Unattended items

    @Test("A new episode's item joins the back of the queue and never runs in the cloud; only a play goes to the front")
    func preparedJoinsTheBackAndAutoTheFront() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(downloader: downloader)
        let first = makeEpisode(episodeID: "unattended-order-first")
        let prepared = makeEpisode(episodeID: "unattended-order-prepared")
        let manual = makeEpisode(episodeID: "unattended-order-manual")
        let played = makeEpisode(episodeID: "unattended-order-auto")
        let laterPrepared = makeEpisode(episodeID: "unattended-order-prepared-2")

        fixture.enqueue(first)
        #expect(await waitUntil { fixture.coordinator.activeEpisodeID == first.episodeID })
        fixture.enqueue(prepared, origin: .prepared)
        fixture.enqueue(manual)
        fixture.enqueue(played, origin: .auto)
        fixture.coordinator.enqueue(
            episode: laterPrepared,
            origin: .prepared,
            downloads: fixture.downloads,
            transcriptionModels: fixture.transcriptionModels,
            appleSpeechAssets: fixture.appleSpeechAssets,
            transcriptions: fixture.transcriptions,
            adAnalyses: fixture.adAnalyses,
            modelContext: fixture.context,
            mode: .cloud,
            refreshSkipZones: { 0 }
        )

        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [
            played.episodeID, prepared.episodeID, manual.episodeID, laterPrepared.episodeID,
        ])
        #expect(fixture.coordinator.queueItems.last?.mode == .onDevice)
        fixture.coordinator.reset()
    }

    @Test("A new episode's item is skipped at launch while its current analysis is attached")
    func preparedLaunchSkipsAnalyzedEpisode() async throws {
        let downloader = ScriptedEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        let fixture = try await makeFixture(downloader: downloader)
        let episode = makeEpisode(episodeID: "unattended-prepared-skip")
        fixture.enqueue(episode)
        #expect(await fixture.waitForDrain())
        #expect(await waitUntil {
            fixture.coordinator.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses
            )
        })

        fixture.enqueue(episode, origin: .prepared)

        #expect(await waitUntil { fixture.coordinator.queueItems.isEmpty && fixture.coordinator.queueState == .idle })
        #expect(fixture.coordinator.drainOutcomes.isEmpty)
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)
    }

    @Test(
        "A lifecycle hold keeps the unattended item at the head with its record, however its own transcription stops, and the playback entry point resumes it",
        arguments: zip(HeldTranscription.allCases, [TestQueueOrigin.auto, .prepared, .auto])
    )
    func lifecycleHoldKeepsItemAndResumes(stop: HeldTranscription, origin: TestQueueOrigin) async throws {
        let transcriber = FirstRunHoldingTranscriber(heldRunCount: stop == .beforeRecord ? 0 : 1)
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "unattended-hold-\(stop)-\(origin)")
        let contents = Data("current audio".utf8)
        if stop == .replacement {
            _ = try await seedDetachedTranscript(for: episode, contents: contents, fixture: fixture)
        } else {
            try insertCompletedDownload(
                for: episode,
                fileStore: fixture.downloadFileStore,
                context: fixture.context,
                contents: contents,
                isHashed: true
            )
            await fixture.loadStores()
        }
        var mayRun = true
        fixture.coordinator.allowsUnattendedWork = { mayRun }
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }
        if stop == .beforeRecord {
            // The first transcribing stage publishes in the same turn as the
            // start, before the store's run has hashed its source.
            var didHold = false
            fixture.coordinator.onStageChange = { stage, _ in
                guard case .transcribing = stage, !didHold else {
                    return
                }
                didHold = true
                mayRun = false
                fixture.coordinator.holdActiveItemForLifecycle(modelContext: fixture.context)
            }
        }

        fixture.enqueue(episode, origin: origin.origin)
        if stop != .beforeRecord {
            #expect(await waitUntil { transcriber.requestCount == 1 })
            #expect(fixture.coordinator.ownsUnattendedActiveTranscription)
            mayRun = false
            fixture.coordinator.holdActiveItemForLifecycle(modelContext: fixture.context)
        }

        #expect(await waitUntil { fixture.coordinator.queueState == .pausedInterrupted })
        #expect(fixture.coordinator.isQueuePausedForEnvironmentalInterrupt)
        #expect(fixture.coordinator.isHoldingUnattendedItem)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [episode.episodeID])
        #expect(fixture.coordinator.drainOutcomes.isEmpty)
        #expect(terminals == [.interrupted])
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).map(\.episodeID) == [episode.episodeID])
        #expect(fixture.presentation(for: episode) == .pausedInBackground)
        switch stop {
        case .fresh:
            let record = try #require(fixture.transcriptions.record(for: episode.episodeID))
            #expect(record.state == .interrupted)
            #expect(record.errorMessage == EpisodeTranscriptionStore.environmentalInterruptMessage)
        case .replacement:
            #expect(fixture.transcriptions.record(for: episode.episodeID)?.state == .completed)
        case .beforeRecord:
            #expect(transcriber.requestCount == 0)
            #expect(fixture.transcriptions.record(for: episode.episodeID) == nil)
        }

        // Still not allowed: the playback entry point leaves it held.
        fixture.coordinator.resumeLifecycleHoldIfAllowed()
        #expect(fixture.coordinator.queueState == .pausedInterrupted)

        mayRun = true
        fixture.coordinator.resumeLifecycleHoldIfAllowed()

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.sourceFileSHA256 == OpenCastSHA256.hash(contents))
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)
    }

    @Test("A lifecycle hold leaves a manual item's transcription and one the pass joined running")
    func lifecycleHoldLeavesManualAndJoinedRuns() async throws {
        let transcriber = FirstRunHoldingTranscriber(heldRunCount: 2)
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false
        )
        let manual = makeEpisode(episodeID: "unattended-hold-manual")
        let joined = makeEpisode(episodeID: "unattended-hold-joined")
        var downloadRecords: [String: EpisodeDownloadRecord] = [:]
        for episode in [manual, joined] {
            downloadRecords[episode.episodeID] = try insertCompletedDownload(
                for: episode,
                fileStore: fixture.downloadFileStore,
                context: fixture.context,
                isHashed: true
            )
        }
        await fixture.loadStores()
        fixture.coordinator.allowsUnattendedWork = { false }

        fixture.enqueue(manual)
        #expect(await waitUntil { transcriber.requestCount == 1 })
        #expect(!fixture.coordinator.ownsUnattendedActiveTranscription)
        fixture.coordinator.holdActiveItemForLifecycle(modelContext: fixture.context)
        transcriber.finishHeldRun()
        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])

        // Generate Transcript already transcribing the episode: the pass
        // joins that run and never starts its own.
        let downloadRecord = try #require(downloadRecords[joined.episodeID])
        let fileURL = try #require(fixture.downloads.localFileURL(for: downloadRecord))
        #expect(fixture.transcriptions.startTranscription(
            joined,
            downloadRecord: downloadRecord,
            localFileURL: fileURL,
            modelSummary: fixture.modelInstaller.summary,
            modelContext: fixture.context
        ))
        #expect(await waitUntil { transcriber.requestCount == 2 })
        fixture.enqueue(joined, origin: .auto)
        #expect(await waitUntil {
            guard case .transcribing = fixture.coordinator.currentStage else {
                return false
            }
            return fixture.coordinator.activeEpisodeID == joined.episodeID
        })
        #expect(!fixture.coordinator.ownsUnattendedActiveTranscription)
        fixture.coordinator.holdActiveItemForLifecycle(modelContext: fixture.context)
        transcriber.finishHeldRun()

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(!fixture.coordinator.isQueuePausedForEnvironmentalInterrupt)
        #expect(transcriber.requestCount == 2)
    }

    @Test("An unattended item that may not run is held without starting its transcription; a manual item is never asked")
    func admissionRefusalHoldsWithoutStarting() async throws {
        let transcriber = FirstRunHoldingTranscriber(heldRunCount: 0)
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false
        )
        let manual = makeEpisode(episodeID: "unattended-admission-manual")
        let prepared = makeEpisode(episodeID: "unattended-admission-prepared")
        for episode in [manual, prepared] {
            try insertCompletedDownload(
                for: episode,
                fileStore: fixture.downloadFileStore,
                context: fixture.context,
                isHashed: true
            )
        }
        await fixture.loadStores()
        var askCount = 0
        var mayRun = false
        fixture.coordinator.allowsUnattendedWork = {
            askCount += 1
            return mayRun
        }

        fixture.enqueue(manual)
        #expect(await fixture.waitForDrain())
        #expect(askCount == 0)
        #expect(transcriber.requestCount == 1)

        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }
        fixture.enqueue(prepared, origin: .prepared)

        #expect(await waitUntil { fixture.coordinator.queueState == .pausedInterrupted })
        #expect(askCount > 0)
        #expect(transcriber.requestCount == 1)
        #expect(fixture.coordinator.isHoldingUnattendedItem)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [prepared.episodeID])
        #expect(terminals == [.interrupted])
        #expect(fixture.coordinator.drainOutcomes.isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).map(\.episodeID) == [prepared.episodeID])
        #expect(fixture.presentation(for: prepared) == .pausedInBackground)

        mayRun = true
        fixture.coordinator.resumeLifecycleHoldIfAllowed()

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
        #expect(transcriber.requestCount == 2)
    }

    @Test("A lifecycle hold that lands while the item may run again resumes at once")
    func lifecycleHoldResumesAtLanding() async throws {
        let transcriber = FirstRunHoldingTranscriber(heldRunCount: 1)
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "unattended-hold-landing")
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            isHashed: true
        )
        await fixture.loadStores()
        var mayRun = true
        fixture.coordinator.allowsUnattendedWork = { mayRun }
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(episode, origin: .auto)
        #expect(await waitUntil { transcriber.requestCount == 1 })
        mayRun = false
        fixture.coordinator.holdActiveItemForLifecycle(modelContext: fixture.context)
        // Playback came back while the run was still stopping.
        mayRun = true

        #expect(await fixture.waitForDrain())
        #expect(terminals == [.interrupted, .drained(completedCount: 1, failedCount: 0)])
        #expect(transcriber.requestCount == 2)
        // The held drain's retention ended before the next drain opened its
        // own, so the next drain ran with its retention open.
        #expect(transcriber.drainRetentionAtRequests == [true, true])
    }

    @Test("A hold after a compute failure waits for the app: neither the playback entry point nor its landing resumes it")
    func computeFailureHoldWaitsForTheApp() async throws {
        let transcriber = ComputeFailureEpisodeTranscriber(failingRequestCount: 2)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber,
            failureEnvironment: EpisodeTranscriptionFailureEnvironment(
                sceneState: .background,
                isProtectedDataAvailable: true
            )
        )
        let episode = makeEpisode(episodeID: "unattended-compute-hold")
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(episode, origin: .auto)

        #expect(await waitUntil { fixture.coordinator.queueState == .pausedInterrupted })
        #expect(fixture.coordinator.isHoldingUnattendedItem)
        #expect(terminals == [.interrupted])
        fixture.coordinator.resumeLifecycleHoldIfAllowed()
        #expect(fixture.coordinator.queueState == .pausedInterrupted)

        fixture.coordinator.resumeQueueForEnvironmentalAutoResume()

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1)])
    }

    @Test(
        "A new episode's item without its trusted download leaves the queue with no outcome and never downloads",
        arguments: PreparedDownloadDefect.allCases
    )
    func preparedWithoutTrustedDownloadIsDropped(defect: PreparedDownloadDefect) async throws {
        let downloader = ScriptedEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        let fixture = try await makeFixture(downloader: downloader, loadsStores: false)
        let prepared = makeEpisode(episodeID: "unattended-drop-\(defect)")
        let next = makeEpisode(episodeID: "unattended-drop-next-\(defect)")
        try insertCompletedDownload(for: next, fileStore: fixture.downloadFileStore, context: fixture.context, isHashed: true)
        var driftedRecord: EpisodeDownloadRecord?
        switch defect {
        case .noRecord:
            break
        case .paused:
            try insertPausedDownload(for: prepared, partial: Data("part".utf8), fixture: fixture)
        case .drifted:
            driftedRecord = try insertCompletedDownload(
                for: prepared,
                fileStore: fixture.downloadFileStore,
                context: fixture.context,
                isHashed: true
            )
        }
        await fixture.loadStores()
        if let driftedRecord {
            // After load, as a file replaced under a kept record is.
            try DownloadFileDefect.drifted.apply(
                to: fixture.downloadFileStore.fileURL(relativePath: try #require(driftedRecord.localRelativePath))
            )
        }
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(prepared, origin: .prepared)
        fixture.enqueue(next)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [next.episodeID])
        #expect(terminals == [.drained(completedCount: 1, failedCount: 0)])
        #expect(downloader.requestCount == 0)
        #expect(fixture.coordinator.queueStatus(for: prepared.episodeID) == .notQueued)
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)
        switch defect {
        case .noRecord:
            #expect(fixture.downloads.record(for: prepared.episodeID) == nil)
        case .paused:
            #expect(fixture.downloads.record(for: prepared.episodeID)?.state == .paused)
        case .drifted:
            #expect(fixture.downloads.record(for: prepared.episodeID)?.state == .completed)
        }
    }

    @Test("A new episode's item that needs the speech model fails with the usual message, and the drain goes on")
    func preparedNeverWaitsOnModelConsent() async throws {
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            modelInstalled: false,
            loadsStores: false
        )
        let prepared = makeEpisode(episodeID: "unattended-consent-prepared")
        let manual = makeEpisode(episodeID: "unattended-consent-manual")
        for episode in [prepared, manual] {
            try insertCompletedDownload(
                for: episode,
                fileStore: fixture.downloadFileStore,
                context: fixture.context,
                isHashed: true
            )
        }
        await fixture.loadStores()

        fixture.enqueue(prepared, origin: .prepared)
        fixture.enqueue(manual)

        #expect(await waitUntil { fixture.coordinator.queueState == .awaitingModelConsent })
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [
            .failed(message: EpisodeTranscriptionError.missingSpeechModel.localizedDescription),
        ])
        #expect(fixture.coordinator.drainOutcomes.map(\.origin) == [.prepared])
        #expect(fixture.coordinator.pendingModelConsentEpisodeID == manual.episodeID)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [manual.episodeID])
        #expect(fixture.modelInstaller.installCallCount == 0)
    }

    @Test(
        "Unattended items transcribe at utility priority; a manual item keeps the inherited one",
        arguments: TestQueueOrigin.allCases
    )
    func unattendedTranscriptionRunsAtUtility(origin: TestQueueOrigin) async throws {
        let transcriber = CompletingEpisodeTranscriber()
        let fixture = try await makeFixture(
            downloader: ScriptedEpisodeAudioDownloader(contents: nil),
            transcriber: transcriber,
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "unattended-priority-\(origin)")
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            isHashed: true
        )
        await fixture.loadStores()

        fixture.enqueue(episode, origin: origin.origin)

        #expect(await fixture.waitForDrain())
        #expect(fixture.coordinator.drainOutcomes.map(\.origin) == [origin.origin])
        let request = try #require(transcriber.lastRequest)
        if origin == .manual {
            #expect(request.priority == nil)
        } else {
            #expect(request.priority == .utility)
            #expect(transcriber.lastBasePriority == .utility)
        }
    }

    // MARK: - Fixture

    @MainActor
    private struct QueueFixture {
        let context: ModelContext
        let downloadFileStore: EpisodeDownloadFileStore
        let transcriptFileStore: EpisodeTranscriptFileStore
        let adAnalysisFileStore: EpisodeAdAnalysisFileStore
        let downloads: DownloadStore
        let transcriptionModels: TranscriptionModelStore
        let appleSpeechAssets: AppleSpeechAssetStore
        let transcriptions: EpisodeTranscriptionStore
        let adAnalyses: EpisodeAdAnalysisStore
        let coordinator: EpisodeAdFreePassCoordinator
        let analysisEnvironment: ScriptedAdAnalysisRunEnvironment
        let modelInstaller: AdFreePassTranscriptionModelInstaller

        func loadStores() async {
            transcriptionModels.load(modelContext: context)
            await downloads.load(modelContext: context)
            transcriptions.load(modelContext: context)
            adAnalyses.load(modelContext: context)
        }

        func enqueue(
            _ episode: EpisodeListItemSnapshot,
            origin: AdFreePassQueueOrigin = .manual,
            engine: AdFreePassTranscriptionEngine = .productDefault,
            prepare: @escaping @MainActor () -> Void = {},
            refreshSkipZones: @escaping @MainActor () -> Int = { 1 }
        ) {
            coordinator.enqueue(
                episode: episode,
                origin: origin,
                downloads: downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses,
                modelContext: context,
                transcriptionEngine: engine,
                prepareBackgroundSession: prepare,
                refreshSkipZones: refreshSkipZones
            )
        }

        func enqueueCloud(_ episode: EpisodeListItemSnapshot, rig: CloudRig) {
            coordinator.enqueue(
                episode: episode,
                origin: .manual,
                downloads: downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses,
                modelContext: context,
                mode: .cloud,
                remoteRunner: rig.runner,
                remoteJobStore: rig.store,
                remotePurchases: rig.purchases,
                refreshSkipZones: { 0 }
            )
        }

        func waitForDrain(outcomeCount: Int = 1) async -> Bool {
            await waitUntil {
                coordinator.queueState == .idle
                    && coordinator.activeEpisodeID == nil
                    && coordinator.drainOutcomes.count == outcomeCount
            }
        }

        func transcriptRecordCount(for episodeID: String) throws -> Int {
            try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>(
                predicate: #Predicate { $0.episodeID == episodeID }
            )).count
        }

        func presentation(
            for episode: EpisodeListItemSnapshot,
            currentZoneCount: Int = 0
        ) -> EpisodeAdFreePassPresentation {
            coordinator.presentation(
                for: episode,
                downloads: downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses,
                currentZoneCount: currentZoneCount
            )
        }
    }

    private func makeFixture(
        downloader: any EpisodeAudioDownloading,
        transcriber: any EpisodeTranscribing = CompletingEpisodeTranscriber(),
        analysisEnvironment: ScriptedAdAnalysisRunEnvironment = ScriptedAdAnalysisRunEnvironment(),
        modelInstalled: Bool = true,
        failureEnvironment: EpisodeTranscriptionFailureEnvironment = .foreground,
        container: ModelContainer? = nil,
        context: ModelContext? = nil,
        temporaryDirectory: URL? = nil,
        loadsStores: Bool = true,
        transcriptReads: TranscriptReadInterceptor? = nil
    ) async throws -> QueueFixture {
        let resolvedContainer = try container ?? OpenCastModelContainerFactory.make(inMemory: true)
        let resolvedContext = context ?? ModelContext(resolvedContainer)
        let directory = try temporaryDirectory ?? makeTemporaryDirectory()
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let transcriptFileStore = EpisodeTranscriptFileStore(
            baseDirectory: directory,
            beforeDocumentReadForTesting: transcriptReads?.hook
        )
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let modelInstaller = AdFreePassTranscriptionModelInstaller(isInstalled: modelInstalled)
        let fixture = QueueFixture(
            context: resolvedContext,
            downloadFileStore: downloadFileStore,
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            downloads: DownloadStore(downloader: downloader, fileStore: downloadFileStore),
            transcriptionModels: TranscriptionModelStore(installer: modelInstaller),
            appleSpeechAssets: AppleSpeechAssetStore(
                provider: FakeAppleSpeechAssetProvider(isTranscriberAvailable: false),
                userDefaults: UserDefaults(suiteName: "adfreepass-coordinator-tests-\(UUID().uuidString)") ?? .standard
            ),
            transcriptions: EpisodeTranscriptionStore(
                transcriber: transcriber,
                fileStore: transcriptFileStore,
                failureEnvironment: { failureEnvironment }
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                client: UnpolledAdAnalysisClient(),
                fileStore: adAnalysisFileStore,
                runEnvironment: analysisEnvironment
            ),
            coordinator: EpisodeAdFreePassCoordinator(),
            analysisEnvironment: analysisEnvironment,
            modelInstaller: modelInstaller
        )
        if loadsStores {
            await fixture.loadStores()
        }
        return fixture
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            title: "Example Episode \(episodeID)",
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    /// Unhashed unless `isHashed`, as a download a pause or a launch
    /// finalize completed is.
    @discardableResult
    private func insertCompletedDownload(
        for episode: EpisodeListItemSnapshot,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext,
        contents: Data? = nil,
        isHashed: Bool = false
    ) throws -> EpisodeDownloadRecord {
        let sourceURL = URL(string: episode.audioURL ?? "https://example.com/audio.mp3")!
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, sourceAudioURL: sourceURL)
        try fileStore.prepareDownloadsDirectory()
        let data = contents ?? Data("downloaded \(episode.episodeID)".utf8)
        try data.write(to: fileStore.fileURL(relativePath: relativePath), options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        )
        if isHashed {
            record.sourceFileSHA256 = OpenCastSHA256.hash(data)
        }
        context.insert(record)
        try context.save()
        return record
    }

    /// A completed transcript, with its document, made from bytes whose
    /// hash is `sourceSHA256`; returns the document's path.
    @discardableResult
    private func insertCompletedTranscript(
        for episode: EpisodeListItemSnapshot,
        sourceSHA256: String,
        byteCount: Int64,
        fixture: QueueFixture
    ) throws -> String {
        let summary = fixture.modelInstaller.summary
        let fingerprint = fixture.transcriptFileStore.fingerprint(
            sourceFileSHA256: sourceSHA256,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256
        )
        let relativePath = fixture.transcriptFileStore.relativePath(episodeID: episode.episodeID, fingerprint: fingerprint)
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 4,
            text: "prior transcript of other bytes",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        try fixture.transcriptFileStore.write(EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            sourceFileByteCount: byteCount,
            sourceFileSHA256: sourceSHA256,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: [segment],
            text: segment.text,
            timings: EpisodeTranscriptTimings(),
            createdAt: createdAt,
            updatedAt: createdAt
        ), relativePath: relativePath)
        fixture.context.insert(EpisodeTranscriptRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            sourceFileByteCount: byteCount,
            sourceFileSHA256: sourceSHA256,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            state: .completed,
            audioDuration: 60,
            completedDuration: 60,
            checkpointCount: 0,
            transcriptRelativePath: relativePath,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        try fixture.context.save()
        return relativePath
    }

    /// A hashed download of `contents` and a completed transcript of other
    /// bytes: the episode a pass must transcribe again.
    private func seedDetachedTranscript(
        for episode: EpisodeListItemSnapshot,
        contents: Data,
        fixture: QueueFixture
    ) async throws -> String {
        try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context,
            contents: contents,
            isHashed: true
        )
        let priorPath = try insertCompletedTranscript(
            for: episode,
            sourceSHA256: OpenCastSHA256.hash(Data("an earlier assembly".utf8)),
            byteCount: 19,
            fixture: fixture
        )
        await fixture.loadStores()
        return priorPath
    }

    @MainActor
    private struct CloudRig {
        let api: RemoteJobFaultInjectingAPI
        let store: RemoteTranscriptionJobStore
        let runner: RemoteTranscriptionJobRunner
        let purchases: RemoteTranscriptionPurchaseStore
    }

    /// A server that delivers a transcript of `contents`, the bytes the
    /// episode's download holds or will hold.
    private func makeCloudRig(for fixture: QueueFixture, delivering contents: Data) throws -> CloudRig {
        let identity = OpenCastRemoteTranscriptionSourceIdentity(
            sha256: OpenCastSHA256.hash(contents),
            byteCount: Int64(contents.count)
        )
        let words = [
            OpenCastRemoteTranscriptWord(start: 0, end: 1, text: "Delivered"),
            OpenCastRemoteTranscriptWord(start: 1, end: 2, text: "remotely."),
        ]
        let text = words.map(\.text).joined(separator: " ")
        let result = OpenCastRemoteTranscriptionResult(
            schemaVersion: 1,
            sourceIdentity: identity,
            languageCode: "en",
            durationSeconds: 60,
            text: text,
            segments: [OpenCastRemoteTranscriptSegment(id: 0, start: 0, end: 2, text: text, words: words)],
            provenance: OpenCastRemoteTranscriptionModelProvenance(
                provider: "cloudflare-workers-ai",
                modelIdentifier: "@cf/openai/whisper-large-v3-turbo",
                modelRevision: nil,
                servingContractVersion: "1",
                requestSettingsSHA256: String(repeating: "a", count: 64),
                chunkManifestSHA256: String(repeating: "b", count: 64),
                normalizedTranscriptSHA256: OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(text),
                pipelineVersion: "stitch-v3"
            ),
            warnings: []
        )
        let api = RemoteJobFaultInjectingAPI(
            pollScript: [OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .resultReady)],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result)
        )
        let suiteName = "adfreepass-coordinator-cloud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = RemoteTranscriptionJobStore(defaults: defaults, diagnostics: RecordingRemoteJobDiagnosticSink())
        return CloudRig(
            api: api,
            store: store,
            runner: RemoteTranscriptionJobRunner(
                api: api,
                downloads: fixture.downloads,
                transcriptions: fixture.transcriptions,
                store: store,
                transportRetryDelays: [],
                localRetryDelays: []
            ),
            purchases: RemoteTranscriptionPurchaseStore(api: api, storeKit: LiveRemoteTranscriptionStoreKitClient())
        )
    }

    private func insertPausedDownload(
        for episode: EpisodeListItemSnapshot,
        partial: Data,
        fixture: QueueFixture
    ) throws {
        let sourceURL = try #require(URL(string: episode.audioURL ?? ""))
        try fixture.downloadFileStore.prepareDownloadsDirectory()
        try partial.write(
            to: fixture.downloadFileStore.pausedPartialFileURL(episodeID: episode.episodeID),
            options: .atomic
        )
        fixture.context.insert(EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: fixture.downloadFileStore.relativePath(
                episodeID: episode.episodeID,
                sourceAudioURL: sourceURL
            ),
            state: .paused,
            bytesReceived: Int64(partial.count),
            bytesExpected: 100,
            entityTag: "paused-etag",
            episodeTitle: episode.title,
            podcastTitle: episode.podcastTitle,
            artworkURLString: episode.artworkURL,
            duration: episode.duration,
            publishedAt: episode.publishedAt
        ))
        try fixture.context.save()
    }

    private func insertInterruptedTranscript(
        for episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        modelSummary: OpenCastWhisperModelInstalledSummary,
        fileStore: EpisodeTranscriptFileStore,
        context: ModelContext
    ) throws {
        let data = try Data(contentsOf: localFileURL)
        let sourceSHA = OpenCastSHA256.hash(data)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, fingerprint: fingerprint)
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 2,
            text: "partial transcript",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        let document = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: downloadRecord.sourceAudioURL,
            sourceFileByteCount: Int64(data.count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [
                EpisodeTranscriptCheckpoint(id: 1, completedDuration: 2, segmentCount: 1, createdAt: .now)
            ],
            segments: [segment],
            text: segment.text,
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: downloadRecord.sourceAudioURL,
            sourceFileByteCount: Int64(data.count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            state: .interrupted,
            audioDuration: 60,
            completedDuration: 2,
            checkpointCount: 1,
            transcriptRelativePath: relativePath
        ))
        try context.save()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAdFreePassTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum ReplacementEnding: CaseIterable, Sendable {
    case cancelled
    case failed

    struct Failure: LocalizedError {
        var errorDescription: String? {
            "Deterministic replacement failure"
        }
    }
}

/// Where a pass loads a completed transcript and then trusts it.
enum TranscriptLoadSite: CaseIterable, Sendable {
    /// The default path's reuse of a completed transcript.
    case reuse
    /// The transcript job state's completed arm, which an explicit engine
    /// reaches past the reuse.
    case jobState
    /// The cloud pass's reuse, before any job.
    case cloudReuse
}

/// Where a lifecycle hold stops the queue's own transcription: a first run
/// with its record, a replacement of a transcript of other bytes, or a start
/// stopped before its record existed.
enum HeldTranscription: CaseIterable, Sendable {
    case fresh
    case replacement
    case beforeRecord
}

enum TestQueueOrigin: CaseIterable, Sendable {
    case manual
    case auto
    case prepared

    var origin: AdFreePassQueueOrigin {
        switch self {
        case .manual: .manual
        case .auto: .auto
        case .prepared: .prepared
        }
    }
}

/// A new episode's download that cannot be trusted as it is.
enum PreparedDownloadDefect: CaseIterable, Sendable {
    case noRecord
    case paused
    case drifted
}

/// Runs an action, once, at the transcript document read it accepts: the
/// reader is suspended in the read meanwhile, as at any document load.
@MainActor
final class TranscriptReadInterceptor {
    private var pending: ((_ relativePath: String) -> Bool)?
    private(set) var actionCount = 0

    /// `action` returns whether it acted on this read; until it does, it
    /// stays armed for the next one.
    func once(_ action: @escaping (_ relativePath: String) -> Bool) {
        pending = action
    }

    nonisolated var hook: @Sendable (_ relativePath: String) async -> Void {
        { [self] relativePath in
            await self.handle(relativePath)
        }
    }

    private func handle(_ relativePath: String) {
        guard let action = pending, action(relativePath) else {
            return
        }
        pending = nil
        actionCount += 1
    }
}

/// Holds each run open until the test ends it, so a replacement can be
/// cancelled, interrupted or failed while the pass waits on it.
private final class HoldingEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation?
    private var storedRequestCount = 0

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                storedRequestCount += 1
                self.continuation = continuation
            }
        }
    }

    func fail(with error: any Error) {
        lock.withLock { continuation }?.finish(throwing: error)
    }

    func unload() async {
    }
}

private struct ImmediateEpisodeAudioDownloader: EpisodeAudioDownloading {
    let contents: Data

    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        try contents.write(to: temporaryURL, options: .atomic)
        await progress(Int64(contents.count), Int64(contents.count))
    }
}

private struct HangingEpisodeAudioDownloader: EpisodeAudioDownloading {
    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        let data = Data("partial".utf8)
        try data.write(to: temporaryURL, options: .atomic)
        await progress(Int64(data.count), 100)
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }
}

/// Completes downloads only after the test releases the episode's gate,
/// so tests can hold an item mid-download while shaping the queue.
nonisolated private final class GatedEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var releasedURLFragments: [String] = []
    private let contents = Data("downloaded audio".utf8)

    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        try contents.write(to: temporaryURL, options: .atomic)
        await progress(Int64(contents.count), Int64(contents.count))
        let url = sourceURL.absoluteString
        while !isReleased(url) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release(urlContaining fragment: String) {
        lock.lock()
        releasedURLFragments.append(fragment)
        lock.unlock()
    }

    private nonisolated func isReleased(_ url: String) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return releasedURLFragments.contains { url.contains($0) }
    }
}

private final class AdFreePassTranscriptionModelInstaller: TranscriptionModelInstalling, @unchecked Sendable {
    var isInstalled: Bool
    let summary: OpenCastWhisperModelInstalledSummary
    var installCallCount = 0

    init(isInstalled: Bool, byteCount: Int64 = 78_900_000) {
        self.isInstalled = isInstalled
        summary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: byteCount,
            treeSHA256: String(repeating: "d", count: 64)
        )
    }

    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        guard isInstalled,
              model == .tinyEnglish,
              version == OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion else {
            throw OpenCastTranscriptionError.modelNotInstalled(
                modelIdentifier: model.rawValue,
                version: version
            )
        }
        return summary
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(
            schemaVersion: 1,
            generatedAt: "2026-07-03T00:00:00Z",
            models: [remoteModel]
        )
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        installCallCount += 1
        progress?(OpenCastWhisperModelInstallProgress(
            modelIdentifier: summary.modelIdentifier,
            version: summary.version,
            completedFileCount: 1,
            totalFileCount: 2,
            completedByteCount: summary.totalByteCount / 2,
            totalByteCount: summary.totalByteCount,
            currentFilePath: "model.bin"
        ))
        try await Task.sleep(for: .milliseconds(20))
        isInstalled = true
        return summary
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
        isInstalled = false
    }

    private var remoteModel: RemoteWhisperModel {
        RemoteWhisperModel(
            modelID: summary.modelIdentifier,
            version: summary.version,
            modelFolder: "model",
            tokenizerFolder: "tokenizer",
            totalByteCount: summary.totalByteCount,
            treeSHA256: summary.treeSHA256,
            files: []
        )
    }
}

private final class CompletingEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0
    var lastRequest: EpisodeTranscriptionRunRequest?
    /// The store's run task, as created: never raised by a waiter.
    var lastBasePriority: TaskPriority?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        lastRequest = request
        lastBasePriority = Task.basePriority
        return Self.completingStream(for: request)
    }

    func unload() async {
    }

    @MainActor
    static func completingStream(
        for request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            let start = request.resumeStart ?? 0
            let segments = [
                OpenCastTranscriptSegment(
                    id: 0,
                    start: start,
                    end: start + 2,
                    text: "hello transcript",
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                ),
                OpenCastTranscriptSegment(
                    id: 1,
                    start: start + 2,
                    end: start + 4,
                    text: "brought to you by tests",
                    avgLogProbability: -0.1,
                    noSpeechProbability: 0.01
                )
            ]
            continuation.yield(.progress(EpisodeTranscriptionProgress(
                audioDuration: 60,
                completedDuration: start,
                checkpointCount: 0,
                currentWindowIndex: 0,
                currentText: nil
            )))
            continuation.yield(.finished(OpenCastTranscriptionResult(
                modelIdentifier: request.modelIdentifier,
                languageCode: request.languageCode,
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                timings: OpenCastTranscriptionTimings(
                    audioDuration: 60,
                    modelLoading: 0.1,
                    audioLoading: 0.1,
                    transcription: 0.2,
                    fullPipeline: 0.4,
                    realTimeFactor: 0.01,
                    decodingFallbackCount: 0,
                    decodingFallback: 0,
                    decodingWindowCount: 1
                )
            )))
            continuation.finish()
        }
    }
}

/// Throws CoreML-shaped errors to exercise the environmental compute
/// classifier: either the first N requests fail outright, or every
/// default-compute request fails while cpuOnly requests complete.
private final class ComputeFailureEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var failingRequestCount: Int
    private let failsDefaultComputeOnly: Bool
    private var requests: [EpisodeTranscriptionRunRequest] = []

    init(failingRequestCount: Int = 0, failsDefaultComputeOnly: Bool = false) {
        self.failingRequestCount = failingRequestCount
        self.failsDefaultComputeOnly = failsDefaultComputeOnly
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        let shouldFail: Bool = {
            lock.lock()
            defer {
                lock.unlock()
            }
            requests.append(request)
            if failsDefaultComputeOnly {
                return request.computeProfile != .cpuOnly
            }
            guard failingRequestCount > 0 else {
                return false
            }
            failingRequestCount -= 1
            return true
        }()

        guard shouldFail else {
            return CompletingEpisodeTranscriber.completingStream(for: request)
        }

        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "com.apple.CoreML", code: 0))
        }
    }

    func unload() async {
    }

    @MainActor
    func requestProfiles(forURLContaining fragment: String) -> [OpenCastTranscriptionComputeProfile] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requests
            .filter { $0.sourceAudioURL.contains(fragment) }
            .map(\.computeProfile)
    }
}
