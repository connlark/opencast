import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcription store")
struct EpisodeTranscriptionStoreTests {
    @Test("Rejects non-completed downloads")
    func rejectsNonCompletedDownloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let store = EpisodeTranscriptionStore(fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory))
        let episode = makeEpisode(episodeID: "not-complete")
        let record = EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            state: .downloading
        )

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(store.lastErrorMessage(for: episode.episodeID) == EpisodeTranscriptionError.downloadNotComplete.localizedDescription)
    }

    @Test("Creates transcript record and document from events")
    func createsTranscriptRecordAndDocumentFromEvents() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let fakeTranscriber = FakeEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-create")
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        let document = try #require(store.document(for: episode.episodeID))
        #expect(transcriptRecord.state == .completed)
        #expect(document.text.contains("hello transcript"))
        #expect(document.segments.map(\.start) == [0, 2])
    }

    @Test("Persists requested engine identity and does not reuse it for another engine")
    func persistsRequestedEngineIdentityAndDoesNotReuseItForAnotherEngine() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "apple speech audio")
        let fakeTranscriber = FakeEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        var idleTimerChanges: [Bool] = []
        store.setIdleTimerDisabled = { idleTimerChanges.append($0) }
        let episode = makeEpisode(episodeID: "transcript-apple-speech")
        let record = completedDownloadRecord(episode: episode)
        let appleIdentity = EpisodeTranscriptionModelIdentity(
            modelIdentifier: "apple-speech-transcriber.en_US",
            version: "iOS 26 test",
            treeSHA256: "asset-status-installed-en_US"
        )

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            engine: .appleSpeech,
            modelIdentity: appleIdentity,
            languageCode: "en-US",
            modelContext: context
        )

        // Wait for run teardown too: jobState reports the in-flight progress
        // entry until the run task's cleanup executes.
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed && !store.hasActiveJob
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        let document = try #require(store.document(for: episode.episodeID))
        #expect(fakeTranscriber.lastRequest?.engine == .appleSpeech)
        #expect(fakeTranscriber.lastRequest?.languageCode == "en-US")
        #expect(transcriptRecord.modelIdentifier == appleIdentity.modelIdentifier)
        #expect(document.modelIdentifier == appleIdentity.modelIdentifier)
        #expect(idleTimerChanges == [true, false])

        let tinySummary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "c", count: 64)
        )
        let tinyIdentity = EpisodeTranscriptionModelIdentity(summary: tinySummary)
        let state = store.jobState(
            for: episode.episodeID,
            downloadRecord: record,
            modelState: .installed(tinySummary),
            modelIdentity: tinyIdentity,
            requiresInstalledWhisperModel: true
        )
        if case .ready = state {
        } else {
            Issue.record("Expected ready for a different requested transcription identity, got \(state)")
        }
    }

    @Test("Interrupted Apple run notifies once and restores the idle timer")
    func interruptedAppleRunNotifiesAndRestoresIdleTimer() async throws {
        let harness = try makeAppleRunHarness(
            episodeID: "apple-interrupted",
            stream: { _ in neverFinishingStream() }
        )
        var interruptionEvents: [String] = []
        var idleTimerChanges: [Bool] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        harness.store.setIdleTimerDisabled = { idleTimerChanges.append($0) }

        harness.store.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            modelContext: harness.context
        )
        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .running
        })

        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(harness.store.record(for: harness.episode.episodeID)?.state == .interrupted)
        #expect(interruptionEvents == ["\(harness.episode.episodeID):false"])
        #expect(idleTimerChanges == [true, false])
    }

    @Test("Cancelling an Apple run does not notify and restores the idle timer")
    func cancelledAppleRunDoesNotNotify() async throws {
        let harness = try makeAppleRunHarness(
            episodeID: "apple-cancelled",
            stream: { _ in neverFinishingStream() }
        )
        var interruptionEvents: [String] = []
        var idleTimerChanges: [Bool] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        harness.store.setIdleTimerDisabled = { idleTimerChanges.append($0) }

        harness.store.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            modelContext: harness.context
        )
        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .running
        })

        harness.store.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )

        #expect(await waitUntil { !harness.store.hasActiveJob })
        #expect(harness.store.record(for: harness.episode.episodeID)?.state == .cancelled)
        #expect(interruptionEvents.isEmpty)
        #expect(idleTimerChanges == [true, false])
    }

    @Test("Failed Apple run does not notify and restores the idle timer")
    func failedAppleRunDoesNotNotify() async throws {
        let harness = try makeAppleRunHarness(
            episodeID: "apple-failed",
            stream: { _ in failingStream(message: "Apple failure") }
        )
        var interruptionEvents: [String] = []
        var idleTimerChanges: [Bool] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        harness.store.setIdleTimerDisabled = { idleTimerChanges.append($0) }

        harness.store.startTranscription(
            harness.episode,
            downloadRecord: harness.downloadRecord,
            localFileURL: harness.audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            modelContext: harness.context
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .failed
                && !harness.store.hasActiveJob
        })
        #expect(interruptionEvents.isEmpty)
        #expect(idleTimerChanges == [true, false])
    }

    @Test("Clamps tiny transcript segment overlaps")
    func clampsTinyTranscriptSegmentOverlaps() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "overlap audio")
        let fakeTranscriber = FakeEpisodeTranscriber(emittedSegments: [
            OpenCastTranscriptSegment(
                id: 10,
                start: 8755.3935546875,
                end: 8760.3935546875,
                text: "Only that the goal is to tamper with numerical results.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 11,
                start: 8760.3916015625,
                end: 8767.3916015625,
                text: "not unauthorized access, not malware propagation, or other common malware objectives.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ])
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-overlap")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.segments.map(\.id) == [0, 1])
        #expect(document.segments[0].end == 8760.3935546875)
        #expect(document.segments[1].start == 8760.3935546875)
        #expect(document.segments[1].end == 8767.3916015625)
    }

    @Test("Drops blank transcript segments before persistence")
    func dropsBlankTranscriptSegmentsBeforePersistence() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "blank segment audio")
        let fakeTranscriber = FakeEpisodeTranscriber(emittedSegments: [
            OpenCastTranscriptSegment(
                id: 20,
                start: 0,
                end: 1,
                text: "   ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 21,
                start: 1,
                end: 4,
                text: "  usable transcript text  ",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 22,
                start: 4,
                end: 5,
                text: "\n\t",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ])
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-blank-segments")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.segments.map(\.id) == [0])
        #expect(document.segments.map(\.text) == ["usable transcript text"])
        #expect(document.text == "usable transcript text")
    }

    @Test("Resume starts from interrupted checkpoint")
    func resumeStartsFromInterruptedCheckpoint() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "resume audio")
        let summary = modelSummary()
        let sourceSHA = try sha256(audioURL)
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: "transcript-resume", fingerprint: fingerprint)
        let baseSegments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 30,
                text: "already done",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        let document = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "transcript-resume",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [
                EpisodeTranscriptCheckpoint(id: 1, completedDuration: 30, segmentCount: 1, createdAt: .now)
            ],
            segments: baseSegments,
            text: "already done",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: "transcript-resume",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            state: .interrupted,
            audioDuration: 60,
            completedDuration: 30,
            checkpointCount: 1,
            transcriptRelativePath: relativePath
        ))
        let fakeTranscriber = FakeEpisodeTranscriber(resumedSegmentStart: 30)
        let store = EpisodeTranscriptionStore(transcriber: fakeTranscriber, fileStore: fileStore)
        store.load(modelContext: context)
        let episode = makeEpisode(episodeID: "transcript-resume")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(fakeTranscriber.lastRequest?.resumeStart == 30)
        let resumedDocument = try #require(store.document(for: episode.episodeID))
        #expect(resumedDocument.segments.map(\.start) == [0, 30, 32])
    }

    @Test("Resumed checkpoint cannot lower completed duration")
    func resumedCheckpointCannotLowerCompletedDuration() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "resume regression audio")
        let summary = modelSummary()
        let sourceSHA = try sha256(audioURL)
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: "transcript-resume-regression", fingerprint: fingerprint)
        let document = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "transcript-resume-regression",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume-regression.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [
                EpisodeTranscriptCheckpoint(id: 1, completedDuration: 30, segmentCount: 0, createdAt: .now)
            ],
            segments: [],
            text: "",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: "transcript-resume-regression",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/transcript-resume-regression.mp3",
            sourceFileByteCount: Int64(try Data(contentsOf: audioURL).count),
            sourceFileSHA256: sourceSHA,
            modelIdentifier: summary.modelIdentifier,
            modelVersion: summary.version,
            modelTreeSHA256: summary.treeSHA256,
            state: .interrupted,
            audioDuration: 60,
            completedDuration: 30,
            checkpointCount: 1,
            transcriptRelativePath: relativePath
        ))
        let fakeTranscriber = RegressingCheckpointEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(transcriber: fakeTranscriber, fileStore: fileStore)
        store.load(modelContext: context)
        let episode = makeEpisode(episodeID: "transcript-resume-regression")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.checkpointCount == 2
        })
        #expect(fakeTranscriber.lastRequest?.resumeStart == 30)
        let resumedRecord = try #require(store.record(for: episode.episodeID))
        #expect(resumedRecord.completedDuration == 30)
        let resumedDocument = try #require(store.document(for: episode.episodeID))
        #expect(resumedDocument.checkpoints.last?.completedDuration == 30)
    }

    @Test("Deleting source download preserves completed transcript")
    func deletingSourceDownloadPreservesCompletedTranscript() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "audio")
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "preserve-completed")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })

        store.handleDownloadDeletion(record, localFileURL: audioURL, modelContext: context)

        #expect(store.record(for: episode.episodeID)?.state == .completed)
        #expect(store.document(for: episode.episodeID) != nil)
    }

    @Test("Active transcription without progress remains running")
    func activeTranscriptionWithoutProgressRemainsRunning() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "loading audio")
        let fakeTranscriber = BlockingThenCompletingEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "loading-before-progress")
        let record = completedDownloadRecord(episode: episode)
        let summary = modelSummary()

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )

        #expect(await waitUntil { fakeTranscriber.requestCount == 1 })
        let state = store.jobState(
            for: episode.episodeID,
            downloadRecord: record,
            modelState: .installed(summary)
        )
        let isRunning: Bool
        if case .running = state {
            isRunning = true
        } else {
            isRunning = false
        }
        #expect(isRunning)
    }

    @Test("Immediate retry after cancel starts a new run")
    func immediateRetryAfterCancelStartsNewRun() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "retry audio")
        let fakeTranscriber = BlockingThenCompletingEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "retry-after-cancel")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )
        #expect(await waitUntil { fakeTranscriber.requestCount == 1 })

        store.cancelTranscription(episodeID: episode.episodeID, modelContext: context)
        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil { fakeTranscriber.requestCount == 2 })
        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
    }

    @Test("Unload runtime waits for active transcription teardown")
    func unloadRuntimeWaitsForActiveTranscriptionTeardown() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "unload audio")
        let fakeTranscriber = SuspendingUnloadEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "unload-runtime")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil { fakeTranscriber.requestCount == 1 })
        let unloadTask = Task { @MainActor in
            await store.unloadRuntime()
        }
        #expect(await waitUntil { fakeTranscriber.isFirstUnloadSuspended })
        #expect(store.hasActiveJob)

        fakeTranscriber.releaseFirstUnload()
        await unloadTask.value

        #expect(!store.hasActiveJob)
        #expect(fakeTranscriber.unloadCallCount >= 1)
    }

    @Test("Nuke waits for active transcription teardown before clearing transcripts")
    func nukeWaitsForActiveTranscriptionTeardownBeforeClearingTranscripts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "nuke transcript audio")
        let fakeTranscriber = SuspendingUnloadEpisodeTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: fakeTranscriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "nuke-waits")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil { store.record(for: episode.episodeID) != nil })
        let nukeTask = Task { @MainActor in
            try await store.nukeAllTranscripts(modelContext: context)
        }
        #expect(await waitUntil { fakeTranscriber.isFirstUnloadSuspended })
        #expect(store.record(for: episode.episodeID) != nil)

        fakeTranscriber.releaseFirstUnload()
        try await nukeTask.value

        #expect(!store.hasActiveJob)
        #expect(store.records.isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeTranscriptRecord>()).isEmpty)
    }

    @Test("Unknown model identifier fails before service fallback")
    func unknownModelIdentifierFailsBeforeServiceFallback() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "unknown model audio")
        let request = EpisodeTranscriptionRunRequest(
            audioFileURL: audioURL,
            languageCode: "en",
            resumeStart: nil,
            sourceAudioURL: "https://example.com/unknown.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: String(repeating: "a", count: 64),
            modelIdentifier: "unknown-model",
            modelVersion: "v1",
            modelTreeSHA256: String(repeating: "b", count: 64)
        )

        let stream = OpenCastEpisodeTranscriber().transcribe(request)

        do {
            for try await _ in stream {
            }
            Issue.record("Expected unsupported model identifier")
        } catch let error as OpenCastTranscriptionError {
            #expect(error == .unsupportedModelIdentifier("unknown-model"))
        } catch {
            Issue.record("Expected unsupportedModelIdentifier, got \(error)")
        }
    }

    @Test("Background CoreML failure retries once on CPU-only and completes")
    func backgroundCoreMLFailureRetriesCPUOnlyAndCompletes() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "cpu fallback audio")
        let transcriber = CoreMLFailingThenCompletingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        let episode = makeEpisode(episodeID: "background-cpu-retry")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe, .cpuOnly])
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
    }

    @Test("CPU fallback resumes from the persisted checkpoint")
    func cpuFallbackResumesFromPersistedCheckpoint() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "checkpoint cpu fallback audio")
        let transcriber = CheckpointThenCoreMLFailingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        let episode = makeEpisode(episodeID: "background-cpu-retry-checkpoint")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe, .cpuOnly])
        #expect(transcriber.requests.last?.resumeStart == 12)
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.segments.map(\.start) == [0, 12, 14])
    }

    @Test("CPU-only environmental failure becomes resumable interruption")
    func cpuOnlyEnvironmentalFailureBecomesInterruption() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "cpu fallback failure audio")
        let transcriber = AlwaysCoreMLFailingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { EpisodeTranscriptionFailureEnvironment(sceneState: .background, isProtectedDataAvailable: true) }
        )
        let episode = makeEpisode(episodeID: "background-cpu-interrupt")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .interrupted
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe, .cpuOnly])
        #expect(transcriptRecord.errorMessage == EpisodeTranscriptionStore.environmentalInterruptMessage)
        #expect(store.hasEnvironmentalInterruptionPending(for: episode.episodeID))
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
    }

    @Test("Foreground CoreML failure remains terminal")
    func foregroundCoreMLFailureRemainsTerminal() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "foreground failure audio")
        let transcriber = AlwaysCoreMLFailingTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { .foreground }
        )
        let episode = makeEpisode(episodeID: "foreground-coreml-failed")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .failed
        })
        #expect(transcriber.requests.map(\.computeProfile) == [.backgroundSafe])
        #expect(store.record(for: episode.episodeID)?.errorMessage == coreMLError().localizedDescription)
    }

    @Test("Partial-preserving cancellation wins over a late CoreML error")
    func partialPreservingCancellationWinsOverLateCoreMLError() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "expiration race audio")
        let transcriber = CheckpointThenManualFailureTranscriber()
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { .foreground }
        )
        var interruptionEvents: [String] = []
        store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }
        let episode = makeEpisode(episodeID: "expiration-coreml-race")
        let record = completedDownloadRecord(episode: episode)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.checkpointCount == 1
        })
        store.interruptActiveJob(modelContext: context)
        transcriber.failWithCoreML()

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .interrupted
                && !store.hasActiveJob
        })
        let transcriptRecord = try #require(store.record(for: episode.episodeID))
        #expect(transcriptRecord.completedDuration == 12)
        #expect(transcriptRecord.errorMessage == nil)
        #expect(store.lastErrorMessage(for: episode.episodeID) == nil)
        #expect(interruptionEvents.isEmpty)
    }

    @Test("Persists word timings with current schema version through checkpoint and final")
    func persistsWordTimingsWithCurrentSchemaVersion() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "worded audio")
        let wordedSegments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 2,
                text: "hello there",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01,
                words: [
                    OpenCastTranscriptWord(start: 0, end: 1, text: "hello"),
                    OpenCastTranscriptWord(start: 1.25, end: 2, text: "there")
                ]
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 2,
                end: 4,
                text: "line level",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        let store = EpisodeTranscriptionStore(
            transcriber: FakeEpisodeTranscriber(emittedSegments: wordedSegments),
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        )
        let episode = makeEpisode(episodeID: "transcript-words")
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: modelSummary(),
            modelContext: context
        )

        #expect(await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed
        })
        let document = try #require(store.document(for: episode.episodeID))
        #expect(document.schemaVersion == EpisodeTranscriptDocument.currentSchemaVersion)
        #expect(document.segments.first?.words == [
            OpenCastTranscriptWord(start: 0, end: 1, text: "hello"),
            OpenCastTranscriptWord(start: 1.25, end: 2, text: "there")
        ])
        #expect(document.segments.last?.words == nil)
    }

    @Test("Reads v1 documents as segments without words")
    func readsV1DocumentsAsSegmentsWithoutWords() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let relativePath = fileStore.relativePath(episodeID: "legacy-episode", fingerprint: "legacy")
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let v1JSON = Data("""
        {
          "schemaVersion": 1,
          "episodeID": "legacy-episode",
          "podcastID": "https://example.com/feed.xml",
          "sourceAudioURL": "https://example.com/legacy.mp3",
          "sourceFileByteCount": 10,
          "sourceFileSHA256": "abc",
          "modelIdentifier": "openai_whisper-tiny.en",
          "modelVersion": "1",
          "modelTreeSHA256": "def",
          "languageCode": "en",
          "audioDuration": 60,
          "checkpoints": [],
          "segments": [
            {"id": 0, "start": 0, "end": 2, "text": "legacy line", "avgLogProbability": -0.1, "noSpeechProbability": 0.01}
          ],
          "text": "legacy line",
          "timings": {
            "modelLoading": 0,
            "audioLoading": 0,
            "transcription": 0,
            "fullPipeline": 0,
            "realTimeFactor": 0,
            "decodingFallbackCount": 0,
            "decodingFallback": 0,
            "decodingWindowCount": 0
          },
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.utf8)
        try v1JSON.write(to: fileURL, options: .atomic)

        let document = try fileStore.read(relativePath: relativePath)
        #expect(document.schemaVersion == 1)
        #expect(document.segments.count == 1)
        #expect(document.segments.first?.words == nil)
    }

    @Test("Reads v2 documents and infers engine provenance from the model identifier")
    func readsV2DocumentsAndInfersEngineProvenance() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let relativePath = fileStore.relativePath(episodeID: "v2-episode", fingerprint: "v2")
        let fileURL = fileStore.fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        func v2JSON(modelIdentifier: String) -> Data {
            Data("""
            {
              "schemaVersion": 2,
              "episodeID": "v2-episode",
              "podcastID": "https://example.com/feed.xml",
              "sourceAudioURL": "https://example.com/v2.mp3",
              "sourceFileByteCount": 10,
              "sourceFileSHA256": "abc",
              "modelIdentifier": "\(modelIdentifier)",
              "modelVersion": "1",
              "modelTreeSHA256": "def",
              "languageCode": "en",
              "audioDuration": 60,
              "checkpoints": [],
              "segments": [],
              "text": "",
              "timings": {
                "modelLoading": 0,
                "audioLoading": 0,
                "transcription": 0,
                "fullPipeline": 0,
                "realTimeFactor": 0,
                "decodingFallbackCount": 0,
                "decodingFallback": 0,
                "decodingWindowCount": 0
              },
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            }
            """.utf8)
        }

        try v2JSON(modelIdentifier: "openai_whisper-tiny.en").write(to: fileURL, options: .atomic)
        let whisperDocument = try fileStore.read(relativePath: relativePath)
        #expect(whisperDocument.schemaVersion == 2)
        #expect(whisperDocument.transcriptionEngine == nil)
        #expect(whisperDocument.resolvedEngineProvenance == .localWhisper)
        #expect(whisperDocument.resolvedSourceMatchMode == nil)

        try v2JSON(modelIdentifier: "apple-speech-transcriber.en-US").write(to: fileURL, options: .atomic)
        let appleDocument = try fileStore.read(relativePath: relativePath)
        #expect(appleDocument.resolvedEngineProvenance == .appleSpeech)
    }

    @Test("Round-trips schema 3 remote provenance fields")
    func roundTripsSchema3RemoteProvenance() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let relativePath = fileStore.relativePath(episodeID: "remote-episode", fingerprint: "remote")
        var document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: "remote-episode",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/remote.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "abc",
            modelIdentifier: "remote-whisper-large-v3-turbo",
            modelVersion: "serving-contract-1",
            modelTreeSHA256: "",
            languageCode: "en",
            audioDuration: 60,
            checkpoints: [],
            segments: [],
            text: "",
            timings: EpisodeTranscriptTimings(),
            createdAt: .now,
            updatedAt: .now
        )
        document.transcriptionEngine = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        document.providerModelIdentifier = "@cf/openai/whisper-large-v3-turbo"
        document.remoteServingContractVersion = "1"
        document.remotePipelineVersion = "pass0"
        document.remoteRequestSettingsSHA256 = "aa"
        document.remoteChunkManifestSHA256 = "bb"
        document.normalizedTranscriptSHA256 = "cc"
        document.remoteJobProvenanceToken = "job-token"
        document.remoteSourceMatchMode = EpisodeRemoteTranscriptSourceMatchMode.serverDeviceHashMatch.rawValue
        try fileStore.write(document, relativePath: relativePath)

        let decoded = try fileStore.read(relativePath: relativePath)
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.resolvedEngineProvenance == .remoteWhisper)
        #expect(decoded.providerModelIdentifier == "@cf/openai/whisper-large-v3-turbo")
        #expect(decoded.providerModelRevision == nil)
        #expect(decoded.remoteChunkManifestSHA256 == "bb")
        #expect(decoded.normalizedTranscriptSHA256 == "cc")
        #expect(decoded.resolvedSourceMatchMode == .serverDeviceHashMatch)
        #expect(decoded.modelTreeSHA256.isEmpty)
    }

    @Test("Remote fingerprint is domain-separated and contract-sensitive")
    func remoteFingerprintIsDomainSeparatedAndContractSensitive() throws {
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        let localFingerprint = fileStore.fingerprint(
            sourceFileSHA256: "abc",
            modelIdentifier: "m",
            modelVersion: "v",
            modelTreeSHA256: "t"
        )
        let remoteFingerprint = fileStore.remoteFingerprint(
            sourceFileSHA256: "abc",
            provider: "cloudflare-workers-ai",
            providerModelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            servingContractVersion: "1",
            pipelineVersion: "pass0"
        )
        let bumpedContractFingerprint = fileStore.remoteFingerprint(
            sourceFileSHA256: "abc",
            provider: "cloudflare-workers-ai",
            providerModelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            servingContractVersion: "2",
            pipelineVersion: "pass0"
        )
        #expect(localFingerprint != remoteFingerprint)
        #expect(remoteFingerprint != bumpedContractFingerprint)
        #expect(remoteFingerprint == fileStore.remoteFingerprint(
            sourceFileSHA256: "abc",
            provider: "cloudflare-workers-ai",
            providerModelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            servingContractVersion: "1",
            pipelineVersion: "pass0"
        ))
    }

    @Test("Record engine provenance distinguishes local, Apple Speech, and remote")
    func recordEngineProvenance() {
        let record = EpisodeTranscriptRecord(
            episodeID: "e",
            podcastID: "p",
            sourceAudioURL: "https://example.com/a.mp3"
        )
        record.modelIdentifier = "openai_whisper-tiny.en"
        #expect(record.engineProvenance == .localWhisper)
        #expect(!record.isAppleSpeechTranscript)
        #expect(!record.isRemoteTranscript)

        record.modelIdentifier = "apple-speech-transcriber.en-US"
        #expect(record.engineProvenance == .appleSpeech)
        #expect(record.isAppleSpeechTranscript)

        record.transcriptionEngineRawValue = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        #expect(record.engineProvenance == .remoteWhisper)
        #expect(record.isRemoteTranscript)
        #expect(!record.isAppleSpeechTranscript)
    }

    @Test("Interrupted improve run restores the prior completed transcript")
    func interruptedImproveRunRestoresPriorCompletedTranscript() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-interrupt",
            secondAttemptStream: { _ in neverFinishingStream() }
        )
        var interruptionEvents: [String] = []
        harness.store.onAppleSpeechRunInterrupted = { episodeID, restored in
            interruptionEvents.append("\(episodeID):\(restored)")
        }

        harness.store.interruptActiveJob(modelContext: harness.context)

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let restored = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(restored.modelIdentifier == harness.priorModelIdentifier)
        #expect(restored.transcriptRelativePath == harness.priorRelativePath)
        #expect(restored.errorMessage == nil)
        let document = try #require(harness.store.document(for: harness.episode.episodeID))
        #expect(document.modelIdentifier == harness.priorModelIdentifier)
        #expect(harness.store.lastErrorMessage(for: harness.episode.episodeID) == nil)
        #expect(interruptionEvents == ["\(harness.episode.episodeID):true"])
    }

    @Test("Cancelled improve run restores the prior completed transcript")
    func cancelledImproveRunRestoresPriorCompletedTranscript() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-cancel",
            secondAttemptStream: { _ in neverFinishingStream() }
        )

        harness.store.cancelTranscription(
            episodeID: harness.episode.episodeID,
            modelContext: harness.context
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let restored = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(restored.modelIdentifier == harness.priorModelIdentifier)
        #expect(restored.transcriptRelativePath == harness.priorRelativePath)
        #expect(harness.store.document(for: harness.episode.episodeID) != nil)
    }

    @Test("Failed improve run restores the prior transcript and surfaces the failure")
    func failedImproveRunRestoresPriorTranscriptAndSurfacesFailure() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-fail",
            secondAttemptStream: { _ in failingStream(message: "Deterministic improve failure") }
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let restored = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(restored.modelIdentifier == harness.priorModelIdentifier)
        #expect(restored.transcriptRelativePath == harness.priorRelativePath)
        #expect(harness.store.document(for: harness.episode.episodeID) != nil)
        #expect(harness.store.lastErrorMessage(for: harness.episode.episodeID) == "Deterministic improve failure")
    }

    @Test("Completed improve replaces the record and deletes the superseded document")
    func completedImproveReplacesRecordAndDeletesSupersededDocument() async throws {
        let harness = try await makeImproveHarness(
            episodeID: "improve-complete",
            secondAttemptStream: { request in FakeEpisodeTranscriber().transcribe(request) }
        )

        #expect(await waitUntil {
            harness.store.record(for: harness.episode.episodeID)?.modelIdentifier == appleImproveIdentity().modelIdentifier
                && harness.store.record(for: harness.episode.episodeID)?.state == .completed
                && !harness.store.hasActiveJob
        })
        let improved = try #require(harness.store.record(for: harness.episode.episodeID))
        #expect(improved.languageCode == "en-US")
        let document = try #require(harness.store.document(for: harness.episode.episodeID))
        #expect(document.modelIdentifier == appleImproveIdentity().modelIdentifier)
        #expect(!harness.fileStore.documentExists(relativePath: harness.priorRelativePath))
    }

    /// Completes a Whisper transcript, then starts an Apple Speech improve run
    /// with `preservesPriorCompletedTranscript` whose stream is test-driven.
    private func makeImproveHarness(
        episodeID: String,
        secondAttemptStream: @escaping @MainActor (EpisodeTranscriptionRunRequest) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>
    ) async throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        store: EpisodeTranscriptionStore,
        fileStore: EpisodeTranscriptFileStore,
        priorModelIdentifier: String,
        priorRelativePath: String
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(in: temporaryDirectory, contents: "improve audio \(episodeID)")
        let fileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, attempt in
            attempt == 1
                ? FakeEpisodeTranscriber().transcribe(request)
                : secondAttemptStream(request)
        }
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: fileStore,
            failureEnvironment: { .foreground }
        )
        let episode = makeEpisode(episodeID: episodeID)
        let record = completedDownloadRecord(episode: episode)
        context.insert(record)

        let summary = modelSummary()
        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            modelSummary: summary,
            modelContext: context
        )
        _ = await waitUntil {
            store.record(for: episode.episodeID)?.state == .completed && !store.hasActiveJob
        }
        guard let priorRecord = store.record(for: episode.episodeID),
              priorRecord.state == .completed,
              let priorRelativePath = priorRecord.transcriptRelativePath
        else {
            throw ImproveHarnessError.priorTranscriptNeverCompleted
        }
        let priorModelIdentifier = priorRecord.modelIdentifier

        store.startTranscription(
            episode,
            downloadRecord: record,
            localFileURL: audioURL,
            engine: .appleSpeech,
            modelIdentity: appleImproveIdentity(),
            languageCode: "en-US",
            preservesPriorCompletedTranscript: true,
            modelContext: context
        )
        // The prior-transcript snapshot is captured just before the improve
        // attempt reaches the transcriber; waiting here keeps the restore
        // paths deterministic for the caller.
        _ = await waitUntil { transcriber.requests.count == 2 }

        return (context, episode, store, fileStore, priorModelIdentifier, priorRelativePath)
    }

    private func makeAppleRunHarness(
        episodeID: String,
        stream: @escaping @MainActor (EpisodeTranscriptionRunRequest) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>
    ) throws -> (
        context: ModelContext,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        audioURL: URL,
        store: EpisodeTranscriptionStore
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let audioURL = try writeAudioPlaceholder(
            in: temporaryDirectory,
            contents: "Apple Speech audio \(episodeID)"
        )
        let transcriber = EpisodeTranscriptionRequestTestTranscriber { request, _ in
            stream(request)
        }
        let store = EpisodeTranscriptionStore(
            transcriber: transcriber,
            fileStore: EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory),
            failureEnvironment: { .foreground }
        )
        let episode = makeEpisode(episodeID: episodeID)
        return (context, episode, completedDownloadRecord(episode: episode), audioURL, store)
    }

    private func modelSummary() -> OpenCastWhisperModelInstalledSummary {
        OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            version: OpenCastWhisperModel.largeV3.defaultRemoteVersion,
            totalByteCount: 10,
            treeSHA256: String(repeating: "b", count: 64)
        )
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode",
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

    private func completedDownloadRecord(episode: EpisodeListItemSnapshot) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            localRelativePath: "EpisodeDownloads/\(episode.episodeID).mp3",
            state: .completed,
            bytesReceived: 10,
            bytesExpected: 10
        )
    }

    private func writeAudioPlaceholder(in directory: URL, contents: String) throws -> URL {
        let url = directory.appending(path: UUID().uuidString).appendingPathExtension("mp3")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastTranscriptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return OpenCastSHA256.hash(data)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private enum ImproveHarnessError: Error {
    case priorTranscriptNeverCompleted
}

@MainActor
private func appleImproveIdentity() -> EpisodeTranscriptionModelIdentity {
    EpisodeTranscriptionModelIdentity(
        modelIdentifier: "apple-speech-transcriber.en_US",
        version: "iOS 26 test",
        treeSHA256: "asset-status-installed-en_US"
    )
}

private func neverFinishingStream() -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.progress(EpisodeTranscriptionProgress(
            audioDuration: 60,
            completedDuration: 1,
            checkpointCount: 0,
            currentWindowIndex: 0,
            currentText: nil
        )))
    }
}

private func failingStream(
    message: String
) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: NSError(
            domain: "EpisodeTranscriptionStoreTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

private func coreMLError() -> NSError {
    NSError(
        domain: "com.apple.CoreML",
        code: 0,
        userInfo: [
            NSLocalizedDescriptionKey: "Unable to compute the asynchronous prediction using ML Program. It can be an invalid input data or broken/unsupported model."
        ]
    )
}

private final class FakeEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var lastRequest: EpisodeTranscriptionRunRequest?
    let resumedSegmentStart: TimeInterval
    let emittedSegments: [OpenCastTranscriptSegment]?

    init(
        resumedSegmentStart: TimeInterval = 0,
        emittedSegments: [OpenCastTranscriptSegment]? = nil
    ) {
        self.resumedSegmentStart = resumedSegmentStart
        self.emittedSegments = emittedSegments
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            let start = request.resumeStart ?? resumedSegmentStart
            let segments = emittedSegments ?? [
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
                    text: "from fake events",
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
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: 1,
                audioDuration: 60,
                completedDuration: segments.first?.end ?? start,
                segments: [segments[0]],
                text: segments[0].text
            )))
            continuation.yield(.finished(OpenCastTranscriptionResult(
                modelIdentifier: request.modelIdentifier,
                languageCode: request.languageCode,
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                timings: OpenCastTranscriptionTimings(
                    audioDuration: 60,
                    modelLoading: 1,
                    audioLoading: 1,
                    transcription: 2,
                    fullPipeline: 4,
                    realTimeFactor: 0.03,
                    decodingFallbackCount: 1,
                    decodingFallback: 0.5,
                    decodingWindowCount: 2
                )
            )))
            continuation.finish()
        }
    }

    func unload() async {
    }
}

private final class CoreMLFailingThenCompletingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requests: [EpisodeTranscriptionRunRequest] = []

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        guard requests.count > 1 else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: coreMLError())
            }
        }

        return FakeEpisodeTranscriber().transcribe(request)
    }

    func unload() async {
    }
}

private final class CheckpointThenCoreMLFailingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requests: [EpisodeTranscriptionRunRequest] = []

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        guard requests.count > 1 else {
            return AsyncThrowingStream { continuation in
                continuation.yield(.progress(EpisodeTranscriptionProgress(
                    audioDuration: 60,
                    completedDuration: 0,
                    checkpointCount: 0,
                    currentWindowIndex: 0,
                    currentText: nil
                )))
                continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                    index: 1,
                    audioDuration: 60,
                    completedDuration: 12,
                    segments: [
                        OpenCastTranscriptSegment(
                            id: 0,
                            start: 0,
                            end: 12,
                            text: "checkpoint before failure",
                            avgLogProbability: -0.1,
                            noSpeechProbability: 0.01
                        )
                    ],
                    text: "checkpoint before failure"
                )))
                continuation.finish(throwing: coreMLError())
            }
        }

        return FakeEpisodeTranscriber().transcribe(request)
    }

    func unload() async {
    }
}

private final class AlwaysCoreMLFailingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requests: [EpisodeTranscriptionRunRequest] = []

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: coreMLError())
        }
    }

    func unload() async {
    }
}

private final class CheckpointThenManualFailureTranscriber: EpisodeTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            continuation.yield(.progress(EpisodeTranscriptionProgress(
                audioDuration: 60,
                completedDuration: 0,
                checkpointCount: 0,
                currentWindowIndex: 0,
                currentText: nil
            )))
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: 1,
                audioDuration: 60,
                completedDuration: 12,
                segments: [
                    OpenCastTranscriptSegment(
                        id: 0,
                        start: 0,
                        end: 12,
                        text: "checkpoint before late failure",
                        avgLogProbability: -0.1,
                        noSpeechProbability: 0.01
                    )
                ],
                text: "checkpoint before late failure"
            )))
        }
    }

    func unload() async {
    }

    func failWithCoreML() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish(throwing: coreMLError())
    }
}

private final class BlockingThenCompletingEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        if requestCount == 1 {
            return AsyncThrowingStream { _ in }
        }

        return FakeEpisodeTranscriber().transcribe(request)
    }

    func unload() async {
    }
}

private final class RegressingCheckpointEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var lastRequest: EpisodeTranscriptionRunRequest?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(EpisodeTranscriptionProgress(
                audioDuration: 60,
                completedDuration: request.resumeStart ?? 0,
                checkpointCount: 1,
                currentWindowIndex: nil,
                currentText: nil
            )))
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: 1,
                audioDuration: 60,
                completedDuration: 4,
                segments: [
                    OpenCastTranscriptSegment(
                        id: 0,
                        start: 0,
                        end: 4,
                        text: "reported from the beginning again",
                        avgLogProbability: -0.1,
                        noSpeechProbability: 0.01
                    )
                ],
                text: "reported from the beginning again"
            )))
            continuation.finish()
        }
    }

    func unload() async {
    }
}

private final class SuspendingUnloadEpisodeTranscriber: EpisodeTranscribing, @unchecked Sendable {
    var requestCount = 0
    var unloadCallCount = 0
    var isFirstUnloadSuspended = false
    private var firstUnloadContinuation: CheckedContinuation<Void, Never>?

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.progress(EpisodeTranscriptionProgress(
                    audioDuration: 60,
                    completedDuration: 0,
                    checkpointCount: 0,
                    currentWindowIndex: 0,
                    currentText: nil
                )))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func unload() async {
        unloadCallCount += 1
        guard unloadCallCount == 1 else {
            return
        }

        isFirstUnloadSuspended = true
        await withCheckedContinuation { continuation in
            firstUnloadContinuation = continuation
        }
    }

    func releaseFirstUnload() {
        firstUnloadContinuation?.resume()
        firstUnloadContinuation = nil
    }
}
