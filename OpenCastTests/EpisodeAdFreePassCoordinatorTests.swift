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
        // The episode-detail controls panel shares the same settled copy.
        #expect(EpisodeAdAnalysisControlsView.outdatedStatusTitle == "Outdated — run again")
    }

    @Test("Queued presentations carry the settled copy")
    func queuedPresentationCopy() {
        let queued = EpisodeAdFreePassPresentation.queued(ahead: 2)
        #expect(queued.statusText == "Queued — 2 ahead")
        #expect(!queued.isPrimaryActionEnabled)
        #expect(EpisodeAdFreePassPresentation.queued(ahead: 0).statusText == "Queued")
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

        // No preemption: the active episode keeps running; auto inserts at the front.
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

        // The verdict computes off-main: the first read may be a provisional
        // false, but it must converge to true without this actor ever
        // decoding the transcript document synchronously.
        #expect(await waitUntil {
            fixture.coordinator.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: fixture.transcriptions,
                adAnalyses: fixture.adAnalyses
            )
        })

        // Dirtying either record stamp invalidates the cached verdict: the
        // next read is provisional false again, then reconverges because the
        // documents themselves are unchanged.
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

    @Test("Acceptance is observable before persistence and background preparation are released")
    func acceptancePrecedesLaunchPreparation() async throws {
        let gate = AsyncTestGate()
        let downloader = GatedEpisodeAudioDownloader()
        let fixture = try await makeFixture(
            downloader: downloader,
            launchPreparationGate: {
                await gate.wait()
            }
        )
        let episode = makeEpisode(episodeID: "queue-acceptance-before-launch")
        var didPrepareBackgroundSession = false

        fixture.enqueue(
            episode,
            prepare: {
                didPrepareBackgroundSession = true
            }
        )

        #expect(fixture.coordinator.queueState == .running)
        #expect(fixture.coordinator.queueStatus(for: episode.episodeID) == .queued(ahead: 0))
        #expect(fixture.presentation(for: episode).phase == .queued)
        #expect(!didPrepareBackgroundSession)
        #expect(fixture.downloads.record(for: episode.episodeID) == nil)
        #expect(try fixture.context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)

        await gate.release()

        #expect(await waitUntil {
            didPrepareBackgroundSession
                && fixture.coordinator.activeEpisodeID == episode.episodeID
        })
        let persistedRecords = try fixture.context.fetch(
            FetchDescriptor<AdFreePassQueueItemRecord>()
        )
        #expect(!persistedRecords.isEmpty)
        downloader.release(urlContaining: episode.episodeID)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle
        })
    }

    @Test("Auto enqueue skips episodes with a current completed analysis")
    func autoEnqueueSkipsAlreadyAnalyzedEpisodes() async throws {
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8))
        )
        let analyzed = makeEpisode(episodeID: "queue-auto-skip-analyzed")
        let fresh = makeEpisode(episodeID: "queue-auto-skip-fresh")

        fixture.enqueue(analyzed)
        #expect(await waitUntil {
            fixture.adAnalyses.record(for: analyzed.episodeID)?.state == .completed
                && fixture.coordinator.queueState == .idle
        })
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)

        fixture.enqueue(analyzed, origin: .auto)
        #expect(await waitUntil {
            fixture.coordinator.queueItems.isEmpty
                && fixture.coordinator.activeEpisodeID == nil
        })
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 1)

        fixture.enqueue(fresh, origin: .auto)
        #expect(await waitUntil {
            fixture.adAnalyses.record(for: fresh.episodeID)?.state == .completed
                && fixture.coordinator.queueState == .idle
        })
        #expect(fixture.analysisEnvironment.resolvedRunIDs.count == 2)
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
        // The interrupted item leaves the queue (re-tap semantics); the rest stay queued.
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
        // Item 1 pays the classified default-compute failure once; item 2
        // starts directly on cpuOnly.
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

        // Simulate relaunch: a fresh coordinator restores from the same store.
        // The original coordinator stays parked (a dead process runs no
        // cancellation cleanup) — resetting it here would let its cancelled
        // pass delete the active episode's queue record across the async
        // fixture construction's suspension points. It is reset in the
        // teardown below instead.
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

        // Restore order follows persisted sequence: auto front insert < first < second.
        #expect(await waitUntil {
            restored.coordinator.queueState == .idle && restored.coordinator.drainOutcomes.count == 3
        })
        #expect(restored.coordinator.drainOutcomes.map(\.episodeID) == [
            third.episodeID, first.episodeID, second.episodeID
        ])
        let remaining = try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>())
        #expect(remaining.isEmpty)

        // Teardown: stop the original coordinator's parked pass.
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

    @Test("Terminal items leave the persisted queue as they finish")
    func terminalItemsLeaveThePersistedQueue() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let fixture = try await makeFixture(
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
        let fixture = try await makeFixture(downloader: HangingEpisodeAudioDownloader())
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

    @Test("Environmental interruption presentation uses background pause copy")
    func environmentalInterruptionPresentationUsesBackgroundPauseCopy() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let fixture = try await makeFixture(
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
        await fixture.loadStores()

        let presentation = fixture.presentation(for: episode)
        #expect(presentation.stage == .interrupted)
        #expect(presentation.statusText == EpisodeTranscriptionStore.environmentalInterruptMessage)
        #expect(presentation.primaryActionTitle == "Resume")
    }

    @Test("An analysis failure surfaces its message as a per-episode failure")
    func analysisFailureSurfacesMessage() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.answer = .failure(.rejected(status: 400), status: 400, listener: .invalidKey)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        let episode = makeEpisode(episodeID: "ad-free-provider-error")
        let expectedMessage = EpisodeAdAnalysisHTTPError(
            statusCode: 503,
            code: "gemini_http_error",
            detail: nil,
            listenerFailure: .invalidKey
        ).localizedDescription

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

        // The card names the reason; the episode can be tried again.
        let expectedMessage = "Your free analyses are used. Add a key in Settings › AI Services."
        #expect(fixture.presentation(for: first).stage == .failed(message: expectedMessage))
        #expect(fixture.presentation(for: first).primaryActionTitle == "Retry")
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

    @Test("A queue an earlier build left deferred at its daily limit restores as an ordinary queue and drains")
    func capDeferredQueueFromEarlierBuildRestores() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let head = makeEpisode(episodeID: "earlier-build-deferred-head")
        let next = makeEpisode(episodeID: "earlier-build-deferred-next")
        // What a deferred queue left behind: its kept head and the rest in
        // order, with the head's analysis failed at the daily limit.
        context.insert(AdFreePassQueueItemRecord(
            episodeID: head.episodeID,
            podcastID: head.podcastID,
            originRawValue: "manual",
            sequence: 1
        ))
        context.insert(AdFreePassQueueItemRecord(
            episodeID: next.episodeID,
            podcastID: next.podcastID,
            originRawValue: "auto",
            sequence: 2
        ))
        let capped = EpisodeAdAnalysisRecord(episodeID: head.episodeID, podcastID: head.podcastID, state: .failed)
        capped.failureKind = .capExceeded
        context.insert(capped)
        try context.save()
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            container: container,
            context: context
        )
        var terminals: [AdFreePassQueueTerminalOutcome] = []
        fixture.coordinator.onQueueTerminal = { terminals.append($0) }
        let episodesByID = [head.episodeID: head, next.episodeID: next]

        fixture.coordinator.restorePersistedQueue(
            resolveEpisode: { episodesByID[$0] },
            downloads: fixture.downloads,
            transcriptionModels: fixture.transcriptionModels,
            appleSpeechAssets: fixture.appleSpeechAssets,
            transcriptions: fixture.transcriptions,
            adAnalyses: fixture.adAnalyses,
            modelContext: context,
            podcastLanguageCode: { _ in nil },
            refreshSkipZones: { _ in 1 }
        )

        #expect(fixture.coordinator.queueState == .running)
        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 2
        })
        #expect(fixture.coordinator.drainOutcomes.map(\.episodeID) == [head.episodeID, next.episodeID])
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.completed(zoneCount: 1), .completed(zoneCount: 1)])
        #expect(terminals == [.drained(completedCount: 2, failedCount: 0)])
        #expect(fixture.adAnalyses.record(for: head.episodeID)?.state == .completed)
        #expect(try context.fetch(FetchDescriptor<AdFreePassQueueItemRecord>()).isEmpty)
    }

    @Test("The analyzing stage carries the run's steps as each window is answered")
    func analyzingStageCarriesRunSteps() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        let gate = AsyncTestGate()
        analysisEnvironment.gate = gate
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment
        )
        var stages: [EpisodeAdFreePassStage] = []
        fixture.coordinator.onStageChange = { stage, _ in stages.append(stage) }
        let episode = makeEpisode(episodeID: "ad-free-steps")

        fixture.enqueue(episode)
        #expect(await waitUntil { analysisEnvironment.sends.count == 1 })
        // One window and, while the run goes, the step still to come.
        let started = EpisodeAdFreePassStage.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 0, total: 2))
        #expect(await waitUntil { fixture.coordinator.currentStage == started })
        #expect(fixture.coordinator.queueSnapshot.fractionCompleted == 0.91)

        await gate.release()
        #expect(await waitUntil { fixture.coordinator.queueState == .idle })
        #expect(stages.contains(started))
        #expect(stages.last == .completed(zoneCount: 1))
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
        let repairing = EpisodeAdFreePassStage.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 2))
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

    @Test("The consent tap on an automatic item makes it the listener's: a key-required end opens the key screen")
    func consentTapOnAutomaticItemPresents() async throws {
        let analysisEnvironment = ScriptedAdAnalysisRunEnvironment()
        analysisEnvironment.route = .keyRequired(.noKey)
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            analysisEnvironment: analysisEnvironment,
            modelInstalled: false
        )
        let episode = makeEpisode(episodeID: "key-required-auto-consent")
        var presentedReasons: [AnalysisKeyRequiredReason] = []
        fixture.coordinator.onKeyRequired = { presentedReasons.append($0) }

        fixture.enqueue(episode, origin: .auto)
        #expect(await waitUntil { fixture.coordinator.queueState == .awaitingModelConsent })
        #expect(presentedReasons.isEmpty)

        fixture.coordinator.resumePausedQueue()

        #expect(await waitUntil { fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1 })
        #expect(fixture.coordinator.drainOutcomes.map(\.kind) == [.keyRequired(.noKey)])
        #expect(presentedReasons == [.noKey])
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

    @Test("Explicit engine override re-transcribes despite a completed transcript from another engine")
    func explicitOverrideRetranscribesDespiteCompletedTranscript() async throws {
        let transcriber = CompletingEpisodeTranscriber()
        // Apple available with installed assets: first create an Apple-identity
        // transcript, then the whisper override must re-run.
        let fixture = try await makeFixture(
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

    @Test("A queue of one publishes the stage sequence with single-item queue context")
    func singleItemQueuePublishesStepFiveStageSequence() async throws {
        let fixture = try await makeFixture(
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

    @Test("A completed download whose file is gone fails the pass and marks the record missing")
    func missingDownloadedFileFailsPassAndMarksRecordMissing() async throws {
        let fixture = try await makeFixture(
            downloader: ImmediateEpisodeAudioDownloader(contents: Data("downloaded audio".utf8)),
            loadsStores: false
        )
        let episode = makeEpisode(episodeID: "pass-missing-file")
        let record = try insertCompletedDownload(
            for: episode,
            fileStore: fixture.downloadFileStore,
            context: fixture.context
        )
        await fixture.loadStores()
        // After load (reconcile sees the file), the file disappears — the
        // delete-races-a-job case reconcile cannot catch.
        let relativePath = try #require(record.localRelativePath)
        try FileManager.default.removeItem(
            at: fixture.downloadFileStore.fileURL(relativePath: relativePath)
        )

        fixture.enqueue(episode)

        #expect(await waitUntil {
            fixture.coordinator.queueState == .idle && fixture.coordinator.drainOutcomes.count == 1
        })
        let outcome = try #require(fixture.coordinator.drainOutcomes.first)
        guard case .failed(message: let message) = outcome.kind else {
            Issue.record("Expected the missing-file pass item to fail.")
            return
        }
        #expect(message == EpisodeDownloadError.missingDownloadedFile.localizedDescription)
        #expect(fixture.downloads.record(for: episode.episodeID)?.state == .missing)
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
        appleSpeechAvailable: Bool = false,
        failureEnvironment: EpisodeTranscriptionFailureEnvironment = .foreground,
        container: ModelContainer? = nil,
        context: ModelContext? = nil,
        temporaryDirectory: URL? = nil,
        loadsStores: Bool = true,
        launchPreparationGate: @escaping @Sendable () async -> Void = {}
    ) async throws -> QueueFixture {
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
                client: UnpolledAdAnalysisClient(),
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory),
                runEnvironment: analysisEnvironment
            ),
            coordinator: EpisodeAdFreePassCoordinator(
                launchPreparationGate: launchPreparationGate
            ),
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
