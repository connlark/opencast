import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad-free pass coordinator")
struct EpisodeAdFreePassCoordinatorTests {
    @Test("Outdated presentation offers a manual re-run with the step-4 copy")
    func outdatedPresentationOffersManualRerun() {
        let outdated = EpisodeAdFreePassPresentation.outdated
        #expect(outdated.statusText == "Outdated — run again")
        #expect(outdated.primaryActionTitle == "Skip Promos & Ads")
        #expect(outdated.isPrimaryActionEnabled)
        #expect(outdated.stage == .idle)
        // The episode-detail controls panel shares the same settled copy.
        #expect(EpisodeAdAnalysisControlsView.outdatedStatusTitle == "Outdated — run again")
    }

    @Test("Queued and cap-deferred presentations carry the settled copy")
    func queuedAndCapDeferredPresentationCopy() {
        let queued = EpisodeAdFreePassPresentation.queued(ahead: 2)
        #expect(queued.statusText == "Queued — 2 ahead")
        #expect(!queued.isPrimaryActionEnabled)
        #expect(EpisodeAdFreePassPresentation.queued(ahead: 0).statusText == "Queued")

        let capDeferred = EpisodeAdFreePassPresentation.capDeferred
        #expect(capDeferred.statusText == "Daily detection limit reached — continues tomorrow")
        #expect(capDeferred.primaryActionTitle == "Retry")
        #expect(capDeferred.isPrimaryActionEnabled)
    }

    @Test("First tap downloads episode and parks at model consent; second tap finishes transcript and analysis")
    func consentThenCompletesOneTapPass() async throws {
        let fixture = try makeFixture(
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
        #expect(fixture.analysisClient.requestCount == 1)
        #expect(refreshCount == 1)
        #expect(fixture.coordinator.queueState == .idle)
        #expect(fixture.presentation(for: episode, currentZoneCount: 1).stage == .completed(zoneCount: 1))
    }

    @Test("Queue drains FIFO with manual tail order, auto front insertion, and no preemption")
    func queueDrainsFIFOWithAutoFrontInsertion() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try makeFixture(downloader: downloader)
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

        // No preemption: the active episode keeps running; auto inserts at the front.
        #expect(fixture.coordinator.activeEpisodeID == first.episodeID)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [
            autoFront.episodeID, second.episodeID, third.episodeID
        ])
        #expect(preparedTitles.count == 3)
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
        #expect(fixture.analysisClient.requestCount == 4)
    }

    @Test("A per-episode failure records the outcome and the queue continues")
    func failureIsolationContinuesQueue() async throws {
        let analysisClient = AdFreePassAnalysisClient(failingRequestIndexes: [2])
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisClient: analysisClient
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

    @Test("Re-enqueueing an already queued or already active episode is idempotent")
    func enqueueIsIdempotentForQueuedAndActiveEpisodes() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try makeFixture(downloader: downloader)
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

        #expect(prepareCount == 2)
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [second.episodeID])

        downloader.release(urlContaining: first.episodeID)
        downloader.release(urlContaining: second.episodeID)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
    }

    @Test("Auto enqueue skips episodes with a current completed analysis")
    func autoEnqueueSkipsAlreadyAnalyzedEpisodes() async throws {
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        )
        let analyzed = makeEpisode(episodeID: "queue-auto-skip-analyzed")
        let fresh = makeEpisode(episodeID: "queue-auto-skip-fresh")

        fixture.enqueue(analyzed)
        #expect(await waitUntil {
            fixture.adAnalyses.record(for: analyzed.episodeID)?.state == .completed
                && fixture.coordinator.queueState == .idle
        })
        #expect(fixture.analysisClient.requestCount == 1)

        fixture.enqueue(analyzed, origin: .auto)
        #expect(fixture.coordinator.queueItems.isEmpty)
        #expect(fixture.coordinator.activeEpisodeID == nil)

        fixture.enqueue(fresh, origin: .auto)
        #expect(await waitUntil {
            fixture.adAnalyses.record(for: fresh.episodeID)?.state == .completed
                && fixture.coordinator.queueState == .idle
        })
        #expect(fixture.analysisClient.requestCount == 2)
    }

    @Test("Model consent pauses the whole queue and the consent tap resumes the drain")
    func consentPausesQueueAndResumes() async throws {
        let fixture = try makeFixture(
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
        let fixture = try makeFixture(downloader: downloader)
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
        // The interrupted item leaves the queue (step-5 re-tap semantics); the rest stay queued.
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
        let fixture = try makeFixture(downloader: downloader)
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
        let fixture = try makeFixture(
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
        // Held, not failure-isolated: the item stays at the head of the queue.
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
        let fixture = try makeFixture(
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
        // Item 1 pays the classified default-compute failure once; item 2
        // starts directly on cpuOnly.
        #expect(transcriber.requestProfiles(forURLContaining: first.episodeID) == [.backgroundSafe, .cpuOnly])
        #expect(transcriber.requestProfiles(forURLContaining: second.episodeID) == [.cpuOnly])
    }

    @Test("Foreground return mid-drain resets the sticky degraded compute profile")
    func foregroundReturnResetsStickyComputeMidDrain() async throws {
        let downloader = GatedEpisodeAudioDownloader()
        let transcriber = ComputeFailureEpisodeTranscriber(failsDefaultComputeOnly: true)
        let fixture = try makeFixture(
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

        // Wait until item 2 is active (gated at download) with item 1's
        // fallback already recorded, then simulate the foreground return.
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
        let fixture = try makeFixture(
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
        context.insert(AdFreePassQueueItemRecord(
            episodeID: "queue-persist-unresolvable",
            podcastID: "https://example.com/feed.xml",
            originRawValue: "manual",
            sequence: 99
        ))
        try context.save()

        let persisted = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(persisted.count == 4)

        // Simulate relaunch: a fresh coordinator restores from the same store.
        fixture.coordinator.reset()
        let episodesByID = [first.episodeID: first, second.episodeID: second, third.episodeID: third]
        let restored = try makeFixture(
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

        // Restore order follows persisted sequence: auto front insert < first < second.
        #expect(await waitUntil {
            restored.coordinator.queueState == .idle && restored.coordinator.drainOutcomes.count == 3
        })
        #expect(restored.coordinator.drainOutcomes.map(\.episodeID) == [
            third.episodeID, first.episodeID, second.episodeID
        ])
        let remaining = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(remaining.isEmpty)
    }

    @Test("Terminal items leave the persisted queue as they finish")
    func terminalItemsLeaveThePersistedQueue() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            container: container,
            context: context
        )
        let episode = makeEpisode(episodeID: "queue-persist-terminal")

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1
        })

        let remaining = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(remaining.isEmpty)
    }

    @Test("Plain cancellation publishes an interrupted terminal stage")
    func plainCancellationPublishesInterruptedTerminalStage() async throws {
        let fixture = try makeFixture(downloader: HangingEpisodeAudioDownloader())
        let episode = makeEpisode(episodeID: "ad-free-cancel")
        var stages: [EpisodeAdFreePassStage] = []
        fixture.coordinator.onStageChange = { stage, _ in stages.append(stage) }

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == episode.episodeID
        })

        fixture.coordinator.cancelActivePass()

        #expect(await waitUntil {
            fixture.coordinator.activeEpisodeID == nil
        })
        #expect(stages.contains(.interrupted))
        fixture.downloads.cancelDownload(episodeID: episode.episodeID, modelContext: fixture.context)
    }

    @Test("Interrupted transcription presentation is resumable")
    func interruptedTranscriptionIsResumable() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let transcriber = CompletingEpisodeTranscriber()
        let fixture = try makeFixture(
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
        fixture.loadStores()

        #expect(fixture.presentation(for: episode).stage == .interrupted)

        fixture.enqueue(episode, refreshSkipZones: { 1 })

        #expect(await waitUntil {
            fixture.adAnalyses.record(for: episode.episodeID)?.state == .completed
        })
        #expect(transcriber.requestCount == 1)
        #expect(transcriber.lastRequest?.resumeStart == 2)
        #expect(fixture.analysisClient.requestCount == 1)
    }

    @Test("Environmental interruption presentation uses background pause copy")
    func environmentalInterruptionPresentationUsesBackgroundPauseCopy() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            container: container,
            context: context,
            temporaryDirectory: temporaryDirectory,
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "ad-free-environmental-interrupted")

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
            context: context,
            errorMessage: EpisodeTranscriptionStore.environmentalInterruptMessage
        )
        fixture.loadStores()

        let presentation = fixture.presentation(for: episode)
        #expect(presentation.stage == .interrupted)
        #expect(presentation.statusText == EpisodeTranscriptionStore.environmentalInterruptMessage)
        #expect(presentation.primaryActionTitle == "Resume")
    }

    @Test("Non-cap analysis failures surface their message as a per-episode failure")
    func nonCapAnalysisFailureSurfacesMessage() async throws {
        let serverError = EpisodeAdAnalysisHTTPError(statusCode: 500, code: "internal", detail: nil)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisClient: AdFreePassAnalysisClient(error: serverError)
        )
        let episode = makeEpisode(episodeID: "ad-free-server-error")
        let expectedMessage = serverError.localizedDescription

        fixture.enqueue(episode)

        #expect(await waitUntil {
            fixture.coordinator.lastFailureMessage == expectedMessage
        })
        #expect(fixture.presentation(for: episode).stage == .failed(message: expectedMessage))
        #expect(fixture.coordinator.queueState == .idle)
    }

    @Test("A cap rejection pauses the queue in capDeferred, retaining and persisting the head item")
    func capRejectionPausesQueueRetainingHead() async throws {
        let capError = EpisodeAdAnalysisHTTPError(
            statusCode: 429,
            code: "daily_request_cap_exceeded",
            detail: nil
        )
        let analysisClient = AdFreePassAnalysisClient(error: capError)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisClient: analysisClient,
            container: container,
            context: context
        )
        let first = makeEpisode(episodeID: "queue-cap-1")
        let second = makeEpisode(episodeID: "queue-cap-2")
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        fixture.enqueue(second)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .capDeferred
        })
        #expect(fixture.coordinator.queueItems.map(\.episodeID) == [first.episodeID, second.episodeID])
        #expect(terminals == [.capDeferred])
        #expect(fixture.coordinator.queueStatus(for: first.episodeID) == .capDeferred)
        #expect(fixture.presentation(for: first) == .capDeferred)
        #expect(fixture.presentation(for: second).statusText == "Queued — 1 ahead")
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.failureKind == .capExceeded)
        // The head item never left the persisted queue: the deferral must
        // survive an overnight quit.
        let persisted = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(persisted.count == 2)
        #expect(analysisClient.requestCount == 1)
    }

    @Test("While cap-deferred, at most one automatic probe per foreground session")
    func capProbeOncePerForegroundSession() async throws {
        let capError = EpisodeAdAnalysisHTTPError(
            statusCode: 429,
            code: "global_capacity_exhausted",
            detail: nil
        )
        let analysisClient = AdFreePassAnalysisClient(error: capError)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisClient: analysisClient
        )
        let episode = makeEpisode(episodeID: "queue-cap-probe")

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .capDeferred
        })
        #expect(analysisClient.requestCount == 1)

        // The failed call was this foreground session's probe: automatic
        // triggers hold until the next background→foreground cycle.
        fixture.coordinator.probeCapDeferredQueueIfAllowed(trigger: .sceneActivated)
        fixture.coordinator.probeCapDeferredQueueIfAllowed(trigger: .refreshCompleted)
        #expect(fixture.coordinator.queueState == .capDeferred)
        #expect(analysisClient.requestCount == 1)

        fixture.coordinator.handleForegroundReturn()
        fixture.coordinator.probeCapDeferredQueueIfAllowed(trigger: .sceneActivated)
        #expect(await waitUntil {
            analysisClient.requestCount == 2 && fixture.coordinator.queueState == .capDeferred
        })

        fixture.coordinator.probeCapDeferredQueueIfAllowed(trigger: .refreshCompleted)
        #expect(analysisClient.requestCount == 2)
    }

    @Test("A manual tap on the deferred episode always probes")
    func manualTapOnDeferredEpisodeAlwaysProbes() async throws {
        let capError = EpisodeAdAnalysisHTTPError(
            statusCode: 429,
            code: "daily_request_cap_exceeded",
            detail: nil
        )
        let analysisClient = AdFreePassAnalysisClient(error: capError)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisClient: analysisClient
        )
        let episode = makeEpisode(episodeID: "queue-cap-manual")

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .capDeferred
        })
        #expect(analysisClient.requestCount == 1)

        fixture.enqueue(episode)

        #expect(await waitUntil {
            analysisClient.requestCount == 2 && fixture.coordinator.queueState == .capDeferred
        })
    }

    @Test("A successful probe after the window resets drains the remainder of the queue")
    func successfulProbeDrainsRemainder() async throws {
        let capError = EpisodeAdAnalysisHTTPError(
            statusCode: 429,
            code: "daily_request_cap_exceeded",
            detail: nil
        )
        let analysisClient = AdFreePassAnalysisClient(error: capError)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisClient: analysisClient,
            container: container,
            context: context
        )
        let first = makeEpisode(episodeID: "queue-cap-resume-1")
        let second = makeEpisode(episodeID: "queue-cap-resume-2")
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }

        fixture.enqueue(first)
        fixture.enqueue(second)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .capDeferred
        })

        // The cap window reset: the next foreground session's probe succeeds
        // and the queue auto-resumes through the remainder.
        analysisClient.error = nil
        fixture.coordinator.handleForegroundReturn()
        fixture.coordinator.probeCapDeferredQueueIfAllowed(trigger: .sceneActivated)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(fixture.adAnalyses.record(for: first.episodeID)?.state == .completed)
        #expect(fixture.adAnalyses.record(for: second.episodeID)?.state == .completed)
        #expect(terminals == [.capDeferred, .drained(completedCount: 2, failedCount: 0)])
        let persisted = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(persisted.isEmpty)
    }

    @Test("Completed transcript is reused by the default path without re-transcribing or re-analyzing")
    func completedTranscriptIsReusedByDefaultPath() async throws {
        let transcriber = CompletingEpisodeTranscriber()
        let fixture = try makeFixture(
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
        #expect(fixture.analysisClient.requestCount == 1)

        fixture.enqueue(episode, refreshSkipZones: {
            refreshCount += 1
            return 1
        })
        #expect(await waitUntil {
            refreshCount == 2 && fixture.coordinator.activeEpisodeID == nil
        })

        #expect(transcriber.requestCount == 1)
        #expect(fixture.analysisClient.requestCount == 1)
    }

    @Test("Explicit engine override re-transcribes despite a completed transcript from another engine")
    func explicitOverrideRetranscribesDespiteCompletedTranscript() async throws {
        let transcriber = CompletingEpisodeTranscriber()
        // Apple available with installed assets: first create an Apple-identity
        // transcript, then the whisper override must re-run.
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            transcriber: transcriber,
            appleSpeechAvailable: true
        )
        let episode = makeEpisode(episodeID: "ad-free-reuse-override")
        var refreshCount = 0

        fixture.enqueue(episode, engine: .appleSpeech, refreshSkipZones: {
            refreshCount += 1
            return 1
        })
        #expect(await waitUntil {
            refreshCount == 1 && fixture.coordinator.activeEpisodeID == nil
        })
        #expect(transcriber.requestCount == 1)
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.modelIdentifier == "apple-speech-transcriber.en_US")

        fixture.enqueue(episode, engine: .whisperTiny, refreshSkipZones: {
            refreshCount += 1
            return 1
        })
        #expect(await waitUntil {
            refreshCount == 2 && fixture.coordinator.activeEpisodeID == nil
        })

        #expect(transcriber.requestCount == 2)
        #expect(fixture.transcriptions.record(for: episode.episodeID)?.modelIdentifier == OpenCastWhisperModel.tinyEnglish.rawValue)
    }

    @Test("A queue of one publishes the step-5 stage sequence with single-item queue context")
    func singleItemQueuePublishesStepFiveStageSequence() async throws {
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        )
        let episode = makeEpisode(episodeID: "queue-single-parity")
        var observed: [(stage: EpisodeAdFreePassStage, context: AdFreePassQueueContext)] = []
        fixture.coordinator.onStageChange = { stage, context in
            observed.append((stage, context))
        }

        fixture.enqueue(episode, refreshSkipZones: { 2 })

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && !fixture.coordinator.drainOutcomes.isEmpty
        })
        #expect(observed.first?.stage == .downloadingEpisode)
        #expect(observed.last?.stage == .completed(zoneCount: 2))
        #expect(observed.allSatisfy { $0.context.totalItemCount == 1 && $0.context.finishedItemCount == 0 })
    }

    @Test("A pass resumes a paused download once and completes")
    func passResumesPausedDownloadAndCompletes() async throws {
        let contents = Data("downloaded audio".utf8)
        let fixture = try makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: contents),
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-resume-paused")
        try insertPausedDownload(for: episode, partial: Data("part".utf8), fixture: fixture)
        fixture.loadStores()

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

    @Test("Pausing again while a pass waits fails that item and drains the queue")
    func repausingDuringPassFailsItemAndDrains() async throws {
        let fixture = try makeFixture(
            downloader: HangingEpisodeAudioDownloader(),
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-repause")
        try insertPausedDownload(for: episode, partial: Data("part".utf8), fixture: fixture)
        fixture.loadStores()

        fixture.enqueue(episode)
        #expect(await waitUntil {
            fixture.downloads.record(for: episode.episodeID)?.state == .downloading
                && fixture.downloads.record(for: episode.episodeID)?.bytesReceived == 7
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
        let fixture = try makeFixture(downloader: downloader)
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
        let fixture = try makeFixture(
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

    // MARK: - Fixture

    @MainActor
    private struct QueueFixture {
        let context: ModelContext
        let downloadFileStore: EpisodeDownloadFileStore
        let transcriptFileStore: EpisodeTranscriptFileStore
        let downloads: DownloadStore
        let transcriptionModels: TranscriptionModelStore
        let appleSpeechAssets: AppleSpeechAssetStore
        let transcriptions: EpisodeTranscriptionStore
        let adAnalyses: EpisodeAdAnalysisStore
        let coordinator: EpisodeAdFreePassCoordinator
        let analysisClient: AdFreePassAnalysisClient
        let modelInstaller: AdFreePassTranscriptionModelInstaller

        func loadStores() {
            transcriptionModels.load(modelContext: context)
            downloads.load(modelContext: context)
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
        analysisClient: AdFreePassAnalysisClient = AdFreePassAnalysisClient(),
        modelInstalled: Bool = true,
        appleSpeechAvailable: Bool = false,
        failureEnvironment: EpisodeTranscriptionFailureEnvironment = .foreground,
        container: ModelContainer? = nil,
        context: ModelContext? = nil,
        temporaryDirectory: URL? = nil,
        loadsStores: Bool = true
    ) throws -> QueueFixture {
        let resolvedContainer = try container ?? OpenCastModelContainerFactory.make(inMemory: true)
        let resolvedContext = context ?? ModelContext(resolvedContainer)
        let directory = try temporaryDirectory ?? makeTemporaryDirectory()
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let modelInstaller = AdFreePassTranscriptionModelInstaller(isInstalled: modelInstalled)
        let fixture = QueueFixture(
            context: resolvedContext,
            downloadFileStore: downloadFileStore,
            transcriptFileStore: transcriptFileStore,
            downloads: DownloadStore(downloader: downloader, fileStore: downloadFileStore),
            transcriptionModels: TranscriptionModelStore(installer: modelInstaller),
            appleSpeechAssets: AppleSpeechAssetStore(
                provider: FakeAppleSpeechAssetProvider(isTranscriberAvailable: appleSpeechAvailable),
                userDefaults: UserDefaults(suiteName: "adfreepass-coordinator-tests-\(UUID().uuidString)") ?? .standard
            ),
            transcriptions: EpisodeTranscriptionStore(
                transcriber: transcriber,
                fileStore: transcriptFileStore,
                failureEnvironment: { failureEnvironment }
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                client: analysisClient,
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory)
            ),
            coordinator: EpisodeAdFreePassCoordinator(),
            analysisClient: analysisClient,
            modelInstaller: modelInstaller
        )
        if loadsStores {
            fixture.loadStores()
        }
        return fixture
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode \(episodeID)",
            summary: nil,
            publishedAt: nil,
            duration: 60,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: episodeID,
            cachedAt: .now
        )
    }

    @discardableResult
    private func insertCompletedDownload(
        for episode: EpisodeListItemSnapshot,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws -> EpisodeDownloadRecord {
        let sourceURL = URL(string: episode.audioURL ?? "https://example.com/audio.mp3")!
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, sourceAudioURL: sourceURL)
        try fileStore.prepareDownloadsDirectory()
        let data = Data("downloaded \(episode.episodeID)".utf8)
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
        context.insert(record)
        try context.save()
        return record
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
        context: ModelContext,
        errorMessage: String? = nil
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
            transcriptRelativePath: relativePath,
            errorMessage: errorMessage
        ))
        try context.save()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAdFreePassTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<240 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
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
private final class GatedEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
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

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        lastRequest = request
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

private final class AdFreePassAnalysisClient: EpisodeAdAnalysisClient, @unchecked Sendable {
    var requestCount = 0
    var error: Error?
    let failingRequestIndexes: Set<Int>

    init(error: Error? = nil, failingRequestIndexes: Set<Int> = []) {
        self.error = error
        self.failingRequestIndexes = failingRequestIndexes
    }

    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        requestCount += 1
        if let error {
            throw error
        }
        if failingRequestIndexes.contains(requestCount) {
            throw EpisodeAdAnalysisHTTPError(statusCode: 500, code: "internal", detail: "probe failure")
        }

        return .completed(EpisodeAdAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [
                EpisodeAdAnalysisAPIAdSpan(
                    kind: .hostReadAd,
                    label: "Test Sponsor",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 2,
                    endTime: 4,
                    confidence: 0.95,
                    evidenceQuote: "brought to you"
                )
            ],
            warnings: [],
            usage: nil
        ))
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }
}
