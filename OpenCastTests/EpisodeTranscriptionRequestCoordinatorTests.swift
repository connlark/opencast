import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcription requests", .serialized)
struct EpisodeTranscriptionRequestCoordinatorTests {
    @Test("Generate resolves Whisper while Apple Speech preference is off")
    func generateResolvesWhisperWhilePreferenceIsOff() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            completedStream(for: request)
        }
        let harness = try await makeHarness(transcriber: transcriber)
        var phases: [EpisodeTranscriptionRequestPhase] = []
        harness.coordinator.onPhaseChange = { phases.append($0) }

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        #expect(transcriber.requests.map(\.engine) == [.whisper])
        let record = try #require(harness.transcriptions.record(for: harness.episode.episodeID))
        #expect(OpenCastWhisperModel.allCases.contains { $0.rawValue == record.modelIdentifier })
        #expect(harness.transcriptions.document(for: harness.episode.episodeID) != nil)
        #expect(phases == [.downloading, .preparingWhisper, .transcribingWhisper, .completed])
    }

    @Test("Generate installs the Whisper model on demand and completes")
    func generateInstallsWhisperModelOnDemand() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            completedStream(for: request)
        }
        // Mirrors the UI-test launch environment: no model installed at
        // start, install happens through the on-demand consent path.
        let models = TranscriptionModelStore(
            installer: OpenCastUITestTranscriptionModelInstaller(isInstalled: false)
        )
        models.loadLocalStatus()
        let harness = try await makeHarness(
            transcriber: transcriber,
            prefersAppleSpeech: false,
            transcriptionModels: models
        )
        var phases: [EpisodeTranscriptionRequestPhase] = []
        harness.coordinator.onPhaseChange = { phases.append($0) }

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        #expect(transcriber.requests.map(\.engine) == [.whisper])
        #expect(phases.contains(.preparingWhisper))
        #expect(models.canStartTranscription)
    }

    @Test("A completed download whose file is gone fails the request and marks the record missing")
    func missingDownloadedFileFailsRequestAndMarksRecordMissing() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            completedStream(for: request)
        }
        let harness = try await makeHarness(transcriber: transcriber)
        let record = try #require(harness.downloads.record(for: harness.episode.episodeID))
        let fileURL = try #require(harness.downloads.localFileURL(for: record))
        try FileManager.default.removeItem(at: fileURL)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil {
            if case .failed = harness.coordinator.request?.phase {
                return true
            }
            return false
        })
        guard case .failed(let message) = harness.coordinator.request?.phase else {
            Issue.record("Expected the missing-file request to fail.")
            return
        }
        #expect(message == EpisodeTranscriptionError.missingDownloadedFile.localizedDescription)
        #expect(harness.downloads.record(for: harness.episode.episodeID)?.state == .missing)
        #expect(transcriber.requests.isEmpty)
    }

    @Test("Model install that never becomes resolvable fails instead of spinning")
    func unresolvableModelInstallFailsInsteadOfSpinning() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            completedStream(for: request)
        }
        // install() reports success (the store flips to .installed from the
        // returned summary) but plan resolution can never see the model —
        // the coordinator must surface a failure, not spin the main actor.
        let models = TranscriptionModelStore(installer: NeverResolvableModelInstaller())
        models.loadLocalStatus()
        let harness = try await makeHarness(
            transcriber: transcriber,
            prefersAppleSpeech: false,
            transcriptionModels: models
        )

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil {
            if case .failed = harness.coordinator.request?.phase {
                return true
            }
            return false
        })
        #expect(transcriber.requests.isEmpty)
    }

    @Test("Apple Speech preference resolves Apple and reports the Apple phase")
    func appleSpeechPreferenceResolvesAppleAndReportsPhase() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            completedStream(for: request)
        }
        let harness = try await makeHarness(
            transcriber: transcriber,
            prefersAppleSpeech: true
        )
        var phases: [EpisodeTranscriptionRequestPhase] = []
        harness.coordinator.onPhaseChange = { phases.append($0) }

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        #expect(transcriber.requests.map(\.engine) == [.appleSpeech])
        #expect(phases == [.downloading, .preparingWhisper, .transcribingAppleSpeech, .completed])
    }

    @Test("Interrupted Apple Speech request reports non-resumable interruption")
    func interruptedAppleSpeechRequestIsNotResumable() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let harness = try await makeHarness(
            transcriber: transcriber,
            prefersAppleSpeech: true
        )

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil {
            harness.coordinator.request?.phase == .transcribingAppleSpeech
                && harness.transcriptions.isActivelyTranscribing(
                    episodeID: harness.episode.episodeID
                )
                && harness.transcriptions.record(for: harness.episode.episodeID)?.state == .running
        })

        harness.coordinator.prepareForLifecycleExit(modelContext: harness.context)

        #expect(await waitUntil { harness.coordinator.request?.phase == .interrupted })
        #expect(!harness.transcriptions.hasActiveJob)
        #expect(harness.coordinator.request?.canResumeFromCheckpoint == false)
        #expect(transcriber.requests.map(\.engine) == [.appleSpeech])
        #expect(harness.transcriptions.record(for: harness.episode.episodeID)?.state == .interrupted)
    }

    @Test("Hard Whisper failure is terminal and a later request can retry")
    func hardWhisperFailureStopsAfterOneAttempt() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            failedStream(message: "Deterministic Whisper failure")
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil {
            harness.coordinator.request?.phase == .failed("Deterministic Whisper failure")
        })
        #expect(transcriber.requests.count == 1)

        let firstRequestID = try #require(harness.coordinator.request?.id)
        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil { transcriber.requests.count == 2 })
        #expect(await waitUntil {
            harness.coordinator.request?.phase == .failed("Deterministic Whisper failure")
        })
        #expect(harness.coordinator.request?.id != firstRequestID)
        #expect(transcriber.requests.map(\.engine) == [.whisper, .whisper])
    }

    @Test("Whisper cancellation is terminal and is not restarted")
    func whisperCancellationStopsAfterOneAttempt() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            cancelledStream()
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .cancelled })
        try await Task.sleep(for: .milliseconds(100))
        #expect(transcriber.requests.map(\.engine) == [.whisper])
        #expect(harness.transcriptions.record(for: harness.episode.episodeID)?.state == .cancelled)
    }

    @Test("Lifecycle exit interrupts Whisper preserving the checkpoint for explicit resume")
    func interruptedWhisperCheckpointResumesOnExplicitRequest() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, attempt in
            attempt == 1
                ? checkpointThenHangStream()
                : completedStream(for: request)
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        // The record carries the checkpoint-persisted duration (12); the
        // beyond-checkpoint progress event (20) stays transient.
        #expect(await waitUntil {
            let record = harness.transcriptions.record(for: harness.episode.episodeID)
            return record?.checkpointCount == 1
                && record?.completedDuration == 12
                && harness.transcriptions.progressByEpisodeID[harness.episode.episodeID]?.completedDuration == 20
        })

        harness.coordinator.prepareForLifecycleExit(modelContext: harness.context)

        #expect(await waitUntil { harness.coordinator.request?.phase == .interrupted })
        let interruptedRecord = try #require(
            harness.transcriptions.record(for: harness.episode.episodeID)
        )
        #expect(interruptedRecord.state == .interrupted)
        #expect(interruptedRecord.completedDuration == 12)
        #expect(interruptedRecord.checkpointCount == 1)
        #expect(harness.transcriptions.document(for: harness.episode.episodeID) != nil)
        #expect(harness.coordinator.request?.canResumeFromCheckpoint == true)
        #expect(transcriber.requests.count == 1)

        #expect(harness.engineSettings.setPrefersAppleSpeech(true, modelContext: harness.context))

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        #expect(transcriber.requests.count == 2)
        #expect(transcriber.requests[1].engine == .whisper)
        #expect(transcriber.requests[1].resumeStart == 12)
    }

    @Test("Corrupt Whisper checkpoint restarts from zero")
    func corruptWhisperCheckpointRestartsFromZero() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, attempt in
            attempt == 1
                ? checkpointThenHangStream()
                : completedStream(for: request)
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        // The record carries the checkpoint-persisted duration (12); the
        // beyond-checkpoint progress event (20) stays transient.
        #expect(await waitUntil {
            let record = harness.transcriptions.record(for: harness.episode.episodeID)
            return record?.checkpointCount == 1
                && record?.completedDuration == 12
                && harness.transcriptions.progressByEpisodeID[harness.episode.episodeID]?.completedDuration == 20
        })
        harness.coordinator.prepareForLifecycleExit(modelContext: harness.context)
        #expect(await waitUntil { harness.coordinator.request?.phase == .interrupted })

        let record = try #require(harness.transcriptions.record(for: harness.episode.episodeID))
        let relativePath = try #require(record.transcriptRelativePath)
        try Data("not a transcript document".utf8).write(
            to: harness.transcriptFiles.fileURL(relativePath: relativePath),
            options: .atomic
        )

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        #expect(transcriber.requests.count == 2)
        #expect(transcriber.requests[1].engine == .whisper)
        #expect(transcriber.requests[1].resumeStart == nil)
    }

    @Test("Interrupted Whisper without a checkpoint restarts from zero")
    func interruptedWhisperWithoutCheckpointIsNotResumable() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.transcriptions.hasActiveJob })
        harness.coordinator.prepareForLifecycleExit(modelContext: harness.context)

        #expect(await waitUntil { harness.coordinator.request?.phase == .interrupted })
        #expect(harness.coordinator.request?.canResumeFromCheckpoint == false)
        #expect(!harness.transcriptions.hasResumableWhisperCheckpoint(
            for: harness.episode.episodeID
        ))
    }

    @Test("Missing completed document becomes a retryable failure")
    func missingCompletedDocumentCanRegenerate() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            completedStream(for: request)
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        let completedRecord = try #require(
            harness.transcriptions.record(for: harness.episode.episodeID)
        )
        try harness.transcriptFiles.delete(relativePath: completedRecord.transcriptRelativePath)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        let missingDocumentMessage = EpisodeTranscriptionError.transcriptDocumentMissing.localizedDescription
        #expect(await waitUntil {
            harness.coordinator.request?.phase == .failed(missingDocumentMessage)
        })
        #expect(harness.transcriptions.record(for: harness.episode.episodeID)?.state == .failed)
        #expect(transcriber.requests.count == 1)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(await waitUntil { harness.coordinator.request?.phase == .completed })
        #expect(transcriber.requests.count == 2)
        #expect(harness.transcriptions.document(for: harness.episode.episodeID) != nil)
    }

    @Test("Data nuke reset invalidates an active transcription request")
    func dataNukeResetCancelsActiveTranscription() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.transcriptions.hasActiveJob })

        harness.coordinator.resetForDataNuke()
        try await harness.transcriptions.nukeAllTranscripts(modelContext: harness.context)

        #expect(harness.coordinator.request == nil)
        #expect(!harness.coordinator.isPresented)
        #expect(!harness.transcriptions.hasActiveJob)
        #expect(harness.transcriptions.records.isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
    }

    @Test("Dismiss and re-present do not duplicate active transcription")
    func dismissAndRepresentKeepWorkRunning() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let harness = try await makeHarness(transcriber: transcriber)

        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )
        #expect(await waitUntil { transcriber.requests.count == 1 })
        let requestID = try #require(harness.coordinator.request?.id)

        harness.coordinator.dismiss(id: requestID)
        #expect(!harness.coordinator.isPresented)
        harness.coordinator.start(
            episode: harness.episode,
            modelContext: harness.context
        )

        #expect(harness.coordinator.isPresented)
        #expect(harness.coordinator.request?.id == requestID)
        #expect(transcriber.requests.count == 1)

        harness.coordinator.resetForDataNuke()
        harness.transcriptions.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )
        #expect(await waitUntil { !harness.transcriptions.hasActiveJob })
    }

    @Test("A same-episode store job attaches without starting a second transcription")
    func sameEpisodeStoreJobAttachesWithoutDuplicateWork() async throws {
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let harness = try await makeHarness(transcriber: transcriber)
        let downloadRecord = try #require(
            harness.downloads.record(for: harness.episode.episodeID)
        )
        let localFileURL = try #require(harness.downloads.localFileURL(for: downloadRecord))
        guard case .success(let ownerReservation) = harness.transcriptions.reserveLocalWork(
            for: harness.episode.episodeID
        ) else {
            Issue.record("Expected the direct workflow to reserve local work")
            return
        }
        #expect(harness.transcriptions.startTranscription(
            harness.episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            modelSummary: modelSummary(),
            localReservation: ownerReservation,
            modelContext: harness.context
        ))
        #expect(await waitUntil { transcriber.requests.count == 1 })

        harness.coordinator.start(episode: harness.episode, modelContext: harness.context)

        #expect(harness.coordinator.request?.phase == .transcribingWhisper)
        #expect(transcriber.requests.count == 1)
        harness.transcriptions.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )
        #expect(await waitUntil { harness.coordinator.request?.phase == .cancelled })
        harness.transcriptions.releaseLocalWork(ownerReservation)
    }

    @Test("A request reservation rejects a direct store start before transcription begins")
    func requestReservationRejectsDirectStoreStart() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try temporaryDirectory()
        let downloader = RecordingHangingEpisodeAudioDownloader()
        let downloads = DownloadStore(
            downloader: downloader,
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: directory)
        )
        let coordinator = EpisodeTranscriptionRequestCoordinator(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptionModels: installedTranscriptionModelStore(),
            transcriptionEngineSettings: TranscriptionEngineSettingsStore(),
            appleSpeechAssets: installedAppleSpeechAssetStore(),
            transcriptions: transcriptions
        )
        coordinator.start(episode: makeEpisode(episodeID: "reserved"), modelContext: context)
        #expect(await waitUntil { downloader.requestCount == 1 })

        let directEpisode = makeEpisode(episodeID: "direct")
        let directFileURL = directory.appending(path: "direct.mp3")
        try Data("direct audio".utf8).write(to: directFileURL)
        let didStart = transcriptions.startTranscription(
            directEpisode,
            downloadRecord: completedDownloadRecord(for: directEpisode),
            localFileURL: directFileURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(!didStart)
        #expect(transcriber.requests.isEmpty)
        #expect(transcriptions.lastErrorMessage(for: directEpisode.episodeID)
            == "Another transcription is in progress.")
        coordinator.resetForDataNuke()
    }

    @Test("An other-episode store job rejects a request before download")
    func otherEpisodeStoreJobRejectsBeforeDownload() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try temporaryDirectory()
        let downloader = RecordingHangingEpisodeAudioDownloader()
        let downloads = DownloadStore(
            downloader: downloader,
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { _, _ in
            hangingProgressStream()
        }
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: directory)
        )
        let blocker = makeEpisode(episodeID: "blocker")
        let blockerFileURL = directory.appending(path: "blocker.mp3")
        try Data("blocker audio".utf8).write(to: blockerFileURL)
        #expect(transcriptions.startTranscription(
            blocker,
            downloadRecord: EpisodeDownloadRecord(
                episodeID: blocker.episodeID,
                podcastID: blocker.podcastID,
                sourceAudioURL: blocker.audioURL ?? "",
                localRelativePath: "blocker.mp3",
                state: .completed,
                bytesReceived: 13,
                bytesExpected: 13
            ),
            localFileURL: blockerFileURL,
            modelSummary: modelSummary(),
            modelContext: context
        ))
        #expect(await waitUntil {
            transcriptions.activeEpisodeID == blocker.episodeID
                && transcriber.requests.count == 1
        })
        let coordinator = EpisodeTranscriptionRequestCoordinator(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptionModels: installedTranscriptionModelStore(),
            transcriptionEngineSettings: TranscriptionEngineSettingsStore(),
            appleSpeechAssets: installedAppleSpeechAssetStore(),
            transcriptions: transcriptions
        )

        coordinator.start(episode: makeEpisode(episodeID: "requested"), modelContext: context)

        #expect(coordinator.request?.phase == .failed("Another transcription is in progress."))
        #expect(downloader.requestCount == 0)
        #expect(transcriber.requests.count == 1)
        transcriptions.cancelTranscription(episodeID: blocker.episodeID, modelContext: context)
        #expect(await waitUntil { !transcriptions.hasActiveJob })
    }

    @Test("A remote reservation rejects a local request before download or model work")
    func remoteReservationRejectsLocalRequestBeforeSideEffects() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = try temporaryDirectory()
        let downloader = RecordingHangingEpisodeAudioDownloader()
        let downloads = DownloadStore(
            downloader: downloader,
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        let transcriptions = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: directory)
        )
        let episode = makeEpisode(episodeID: "remote-owned")
        let reservationResult = transcriptions.workCoordinator.reserveRemote(
            episodeID: episode.episodeID,
            activeLocalEpisodeID: nil
        )
        guard case .success(let reservation) = reservationResult else {
            Issue.record("Expected remote work to reserve the episode")
            return
        }
        let coordinator = EpisodeTranscriptionRequestCoordinator(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptionModels: installedTranscriptionModelStore(),
            transcriptionEngineSettings: TranscriptionEngineSettingsStore(),
            appleSpeechAssets: installedAppleSpeechAssetStore(),
            transcriptions: transcriptions
        )

        coordinator.start(episode: episode, modelContext: context)

        #expect(coordinator.request?.phase == .failed(
            "A remote transcription of this episode is already in progress."
        ))
        #expect(coordinator.isPresented)
        #expect(downloader.requestCount == 0)
        #expect(!transcriptions.hasActiveJob)
        transcriptions.workCoordinator.releaseRemote(reservation)
    }

    @Test("Data nuke cancels a waiting request without recreating download state")
    func dataNukeCancelsWaitingRequest() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptionRequestNukeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let downloader = RecordingHangingEpisodeAudioDownloader()
        let downloadStore = DownloadStore(
            downloader: downloader,
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        let transcriptStore = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: directory)
        )
        let appModel = OpenCastAppModel(
            cacheController: OpenCastCacheController(
                rootDirectory: directory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloadStore,
            transcriptionModels: installedTranscriptionModelStore(),
            appleSpeechAssets: installedAppleSpeechAssetStore(),
            transcriptions: transcriptStore,
            adAnalyses: EpisodeAdAnalysisStore(
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: directory)
            ),
            syncStatus: SyncStatusStore(
                accountStatusProvider: AvailableCloudKitAccountStatusProvider()
            ),
            allowsAutomaticFeedRefresh: false
        )
        let episode = makeEpisode(episodeID: "nuke-wait")

        appModel.transcriptionRequests.start(
            episode: episode,
            modelContext: context
        )
        #expect(await waitUntil { downloader.requestCount == 1 })
        #expect(downloadStore.record(for: episode.episodeID)?.state == .downloading)

        try await appModel.nukeAllData(modelContext: context)
        try await Task.sleep(for: .milliseconds(100))

        #expect(appModel.transcriptionRequests.request == nil)
        #expect(!appModel.transcriptionRequests.isPresented)
        #expect(downloader.requestCount == 1)
        #expect(downloadStore.records.isEmpty)
        #expect(transcriptStore.records.isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
    }

    private func makeHarness(
        transcriber: EpisodeTranscriptionRequestTestTranscriber
    ) async throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        transcriptFiles: EpisodeTranscriptFileStore,
        transcriptions: EpisodeTranscriptionStore,
        engineSettings: TranscriptionEngineSettingsStore,
        downloads: DownloadStore,
        coordinator: EpisodeTranscriptionRequestCoordinator
    ) {
        try await makeHarness(transcriber: transcriber, prefersAppleSpeech: false)
    }

    private func makeHarness(
        transcriber: EpisodeTranscriptionRequestTestTranscriber,
        prefersAppleSpeech: Bool,
        transcriptionModels: TranscriptionModelStore? = nil
    ) async throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        transcriptFiles: EpisodeTranscriptFileStore,
        transcriptions: EpisodeTranscriptionStore,
        engineSettings: TranscriptionEngineSettingsStore,
        downloads: DownloadStore,
        coordinator: EpisodeTranscriptionRequestCoordinator
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptionRequestTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let downloadFiles = EpisodeDownloadFileStore(baseDirectory: directory)
        try downloadFiles.prepareDownloadsDirectory()
        let episode = makeEpisode(episodeID: UUID().uuidString)
        let sourceURL = try #require(URL(string: episode.audioURL ?? ""))
        let relativePath = downloadFiles.relativePath(
            episodeID: episode.episodeID,
            sourceAudioURL: sourceURL
        )
        let audioData = Data("deterministic request audio".utf8)
        try audioData.write(to: downloadFiles.fileURL(relativePath: relativePath))
        context.insert(EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(audioData.count),
            bytesExpected: Int64(audioData.count)
        ))
        try context.save()

        let downloads = DownloadStore(fileStore: downloadFiles)
        await downloads.load(modelContext: context)
        let transcriptFiles = EpisodeTranscriptFileStore(baseDirectory: directory)
        let transcriptions = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: transcriptFiles
        )
        let engineSettings = TranscriptionEngineSettingsStore()
        if prefersAppleSpeech {
            #expect(engineSettings.setPrefersAppleSpeech(true, modelContext: context))
        }
        let coordinator = EpisodeTranscriptionRequestCoordinator(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: downloads,
            transcriptionModels: transcriptionModels ?? installedTranscriptionModelStore(),
            transcriptionEngineSettings: engineSettings,
            appleSpeechAssets: installedAppleSpeechAssetStore(),
            transcriptions: transcriptions
        )
        return (context, episode, transcriptFiles, transcriptions, engineSettings, downloads, coordinator)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func modelSummary() -> OpenCastWhisperModelInstalledSummary {
        OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "b", count: 64)
        )
    }

    private func completedDownloadRecord(
        for episode: EpisodeListItemSnapshot
    ) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            localRelativePath: "direct.mp3",
            state: .completed,
            bytesReceived: 12,
            bytesExpected: 12
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "OpenCastTranscriptionCoordinationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

@MainActor
private func installedTranscriptionModelStore() -> TranscriptionModelStore {
    let store = TranscriptionModelStore(
        installer: OpenCastUITestTranscriptionModelInstaller(isInstalled: true)
    )
    store.loadLocalStatus()
    return store
}

@MainActor
private func installedAppleSpeechAssetStore() -> AppleSpeechAssetStore {
    AppleSpeechAssetStore(provider: FakeAppleSpeechAssetProvider())
}

/// `install` succeeds (so the store reports `.installed` from the returned
/// summary) while `installedSummary` keeps throwing — the disk/state
/// disagreement shape behind the resolve/ensure spin guard.
private struct NeverResolvableModelInstaller: TranscriptionModelInstalling {
    func installedSummary(model: OpenCastWhisperModel, version: String) throws -> OpenCastWhisperModelInstalledSummary {
        throw OpenCastTranscriptionError.modelNotInstalled(
            modelIdentifier: model.rawValue,
            version: version
        )
    }

    func fetchManifest() async throws -> RemoteWhisperModelManifest {
        RemoteWhisperModelManifest(
            schemaVersion: 1,
            generatedAt: "2026-06-29T00:00:00Z",
            models: OpenCastWhisperModel.allCases.map { model in
                RemoteWhisperModel(
                    modelID: model.rawValue,
                    version: model.defaultRemoteVersion,
                    modelFolder: "model",
                    tokenizerFolder: "tokenizer",
                    totalByteCount: 1000,
                    treeSHA256: String(repeating: "c", count: 64),
                    files: []
                )
            }
        )
    }

    func install(
        manifest: RemoteWhisperModelManifest,
        model: OpenCastWhisperModel,
        version: String,
        progress: OpenCastWhisperModelInstallProgressHandler?
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        OpenCastWhisperModelInstalledSummary(
            modelIdentifier: model.rawValue,
            version: model.defaultRemoteVersion,
            totalByteCount: 1000,
            treeSHA256: String(repeating: "c", count: 64)
        )
    }

    func deleteInstalledModel(model: OpenCastWhisperModel, version: String) throws {
    }
}

private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
    .fixture(
        episodeID: episodeID,
        title: "Transcription Request",
        audioURL: "https://example.com/\(episodeID).mp3",
        guid: episodeID
    )
}

@MainActor
private func completedStream(
    for request: EpisodeTranscriptionRunRequest
) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        let start = request.resumeStart ?? 0
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: start,
            end: start + 2,
            text: "Deterministic transcript",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        continuation.yield(.finished(OpenCastTranscriptionResult(
            modelIdentifier: request.modelIdentifier,
            languageCode: request.languageCode,
            text: segment.text,
            segments: [segment],
            timings: OpenCastTranscriptionTimings(
                audioDuration: 60,
                modelLoading: 0,
                audioLoading: 0,
                transcription: 1,
                fullPipeline: 1,
                realTimeFactor: 0.02,
                decodingFallbackCount: 0,
                decodingFallback: 0,
                decodingWindowCount: 1
            )
        )))
        continuation.finish()
    }
}

private func hangingProgressStream() -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.progress(EpisodeTranscriptionProgress(
            audioDuration: 60,
            completedDuration: 1,
            checkpointCount: 0,
            currentWindowIndex: 0,
            currentText: "Testing"
        )))
    }
}

private func checkpointThenHangStream() -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        let segment = OpenCastTranscriptSegment(
            id: 0,
            start: 0,
            end: 12,
            text: "Saved checkpoint",
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
        continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
            index: 1,
            audioDuration: 60,
            completedDuration: 12,
            segments: [segment],
            text: segment.text
        )))
        continuation.yield(.progress(EpisodeTranscriptionProgress(
            audioDuration: 60,
            completedDuration: 20,
            checkpointCount: 1,
            currentWindowIndex: 1,
            currentText: "Beyond the saved checkpoint"
        )))
    }
}

private func failedStream(
    message: String
) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: NSError(
            domain: "EpisodeTranscriptionRequestTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

private func cancelledStream() -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: CancellationError())
    }
}
