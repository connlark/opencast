import Foundation
import Observation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import UIKit

@Observable
final class EpisodeTranscriptionStore {
    static let environmentalInterruptMessage = "Paused in background - will resume."

    private(set) var records: [EpisodeTranscriptRecord] = []
    private(set) var progressByEpisodeID: [String: EpisodeTranscriptionProgress] = [:]
    private(set) var lastErrorMessage: String?
    private var lastErrorEpisodeID: String?

    @ObservationIgnored private let transcriber: any EpisodeTranscribing
    @ObservationIgnored private let fileStore: EpisodeTranscriptFileStore
    @ObservationIgnored private let failureEnvironment: @MainActor () -> EpisodeTranscriptionFailureEnvironment
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeEpisodeID: String?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var activeSourceFileURL: URL?
    @ObservationIgnored private var activeEngine: EpisodeTranscriptionEngine?
    @ObservationIgnored private var activeCancellationPreservesPartial = false
    @ObservationIgnored private var activePreservesPriorCompletedTranscript = false
    @ObservationIgnored private var priorCompletedTranscriptSnapshot: PriorCompletedTranscriptSnapshot?
    @ObservationIgnored private let stateChanges = StoreChangeNotifier()
    @ObservationIgnored private var lastProgressPublicationByEpisodeID: [String: Date] = [:]
    @ObservationIgnored var onEpisodeStateChanged: ((String) -> Void)?
    @ObservationIgnored var onAppleSpeechRunInterrupted: ((_ episodeID: String, _ restoredPriorTranscript: Bool) -> Void)?
    @ObservationIgnored var setIdleTimerDisabled: (Bool) -> Void = {
        UIApplication.shared.isIdleTimerDisabled = $0
    }
    /// Set when a run's protected default-compute attempt was classified as an
    /// environmental compute failure and retried on `.cpuOnly` — the queue
    /// coordinator reads this to carry the degraded profile across items
    /// within one protected drain (decision 20).
    @ObservationIgnored private(set) var lastEnvironmentalComputeFallbackEpisodeID: String?

    init(
        transcriber: any EpisodeTranscribing = OpenCastEpisodeTranscriber(),
        fileStore: EpisodeTranscriptFileStore = EpisodeTranscriptFileStore(),
        failureEnvironment: @escaping @MainActor () -> EpisodeTranscriptionFailureEnvironment = EpisodeTranscriptionFailureEnvironment.current
    ) {
        self.transcriber = transcriber
        self.fileStore = fileStore
        self.failureEnvironment = failureEnvironment
    }

    var hasActiveJob: Bool {
        activeTask != nil
    }

    func isActivelyTranscribing(episodeID: String) -> Bool {
        activeTask != nil && activeEpisodeID == episodeID
    }

    func activeEngine(for episodeID: String) -> EpisodeTranscriptionEngine? {
        guard isActivelyTranscribing(episodeID: episodeID) else {
            return nil
        }
        return activeEngine
    }

    func hasResumableWhisperCheckpoint(for episodeID: String) -> Bool {
        guard let record = record(for: episodeID), record.state == .interrupted else {
            return false
        }
        return hasWhisperResumeMetadata(record)
    }

    var changeSequence: Int {
        stateChanges.sequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await stateChanges.wait(after: sequence)
    }

    func waitForActiveJobToStop(episodeID: String) async throws {
        while activeEpisodeID == episodeID, let activeTask {
            try Task.checkCancellation()
            await activeTask.value
        }
        try Task.checkCancellation()
    }

    func load(modelContext: ModelContext) {
        priorCompletedTranscriptSnapshot = nil
        do {
            try reconcile(modelContext: modelContext)
            try reload(modelContext: modelContext)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            recordFailure(error)
        }
    }

    func record(for episodeID: String) -> EpisodeTranscriptRecord? {
        records.first { $0.episodeID == episodeID }
    }

    func lastErrorMessage(for episodeID: String) -> String? {
        guard lastErrorEpisodeID == episodeID else {
            return nil
        }
        return lastErrorMessage
    }

    func hasEnvironmentalInterruptionPending(for episodeID: String) -> Bool {
        guard let record = record(for: episodeID) else {
            return false
        }

        return isEnvironmentalInterruption(record)
    }

    func isEnvironmentalInterruption(_ record: EpisodeTranscriptRecord) -> Bool {
        record.state == .interrupted && record.errorMessage == Self.environmentalInterruptMessage
    }

    func document(for episodeID: String) -> EpisodeTranscriptDocument? {
        guard let record = record(for: episodeID),
              let relativePath = record.transcriptRelativePath
        else {
            return nil
        }
        return try? fileStore.read(relativePath: relativePath)
    }

    func hasCompletedTranscript(for episodeID: String) -> Bool {
        guard let record = record(for: episodeID), record.state == .completed else {
            return false
        }

        return record.transcriptRelativePath != nil
    }

    func hasCompletedDocument(for episodeID: String) -> Bool {
        guard let record = record(for: episodeID),
              record.state == .completed,
              let relativePath = record.transcriptRelativePath
        else {
            return false
        }

        return fileStore.documentExists(relativePath: relativePath)
    }

    func markTranscriptDocumentUnavailable(episodeID: String, modelContext: ModelContext) {
        guard let record = record(for: episodeID), record.state == .completed else {
            return
        }
        markFailed(
            episodeID: episodeID,
            relativePath: record.transcriptRelativePath,
            error: EpisodeTranscriptionError.transcriptDocumentMissing,
            modelContext: modelContext
        )
    }

    func loadDocument(for episodeID: String) async throws -> EpisodeTranscriptDocument {
        guard let record = record(for: episodeID),
              let relativePath = record.transcriptRelativePath
        else {
            throw EpisodeTranscriptionError.transcriptDocumentMissing
        }
        return try await fileStore.readOffCaller(relativePath: relativePath)
    }

    func jobState(
        for episodeID: String,
        downloadRecord: EpisodeDownloadRecord?,
        modelState: TranscriptionModelState,
        modelIdentity: EpisodeTranscriptionModelIdentity? = nil,
        requiresInstalledWhisperModel: Bool = true
    ) -> EpisodeTranscriptionJobState {
        if let progress = progressByEpisodeID[episodeID] {
            return .running(progress)
        }

        let isActiveEpisode = activeEpisodeID == episodeID && activeTask != nil
        let record = record(for: episodeID)
        if isActiveEpisode {
            return .running(progress(from: record))
        }

        if let record, recordMatches(record, identity: modelIdentity) {
            switch record.state {
            case .completed:
                return .completed(record)
            case .failed:
                return .failed(record)
            case .cancelled:
                return .cancelled(record)
            case .interrupted:
                return .interrupted(record)
            case .queued, .running:
                return .interrupted(record)
            }
        }

        guard downloadRecord?.state == .completed else {
            return .downloadRequired
        }

        guard requiresInstalledWhisperModel else {
            return .ready
        }

        switch modelState {
        case .installed:
            return .ready
        case .notInstalled, .failed, .unknown:
            return .modelRequired
        case .checking, .installing, .deleting, .repairAvailable:
            return .modelBusy
        }
    }

    @discardableResult
    func startTranscription(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        modelSummary: OpenCastWhisperModelInstalledSummary,
        modelContext: ModelContext
    ) -> Bool {
        if let activeTask,
           !(activeEpisodeID == episode.episodeID && activeTask.isCancelled) {
            recordFailure(EpisodeTranscriptionError.anotherJobActive, episodeID: episode.episodeID)
            return false
        }

        do {
            try validate(downloadRecord: downloadRecord, episode: episode, localFileURL: localFileURL)
        } catch {
            recordFailure(error, episodeID: episode.episodeID)
            return false
        }

        clearFailure(episodeID: episode.episodeID)
        let modelIdentity = EpisodeTranscriptionModelIdentity(summary: modelSummary)
        return startTranscription(
            episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            engine: .whisper,
            modelIdentity: modelIdentity,
            languageCode: "en",
            modelContext: modelContext
        )
    }

    @discardableResult
    func startTranscription(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        engine: EpisodeTranscriptionEngine,
        modelIdentity: EpisodeTranscriptionModelIdentity,
        languageCode: String,
        runLanguageCode: String? = nil,
        initialComputeProfile: OpenCastTranscriptionComputeProfile = .backgroundSafe,
        preservesPriorCompletedTranscript: Bool = false,
        modelContext: ModelContext
    ) -> Bool {
        if let activeTask,
           !(activeEpisodeID == episode.episodeID && activeTask.isCancelled) {
            recordFailure(EpisodeTranscriptionError.anotherJobActive, episodeID: episode.episodeID)
            return false
        }

        do {
            try validate(downloadRecord: downloadRecord, episode: episode, localFileURL: localFileURL)
        } catch {
            recordFailure(error, episodeID: episode.episodeID)
            return false
        }

        clearFailure(episodeID: episode.episodeID)
        clearTransientProgress(episodeID: episode.episodeID)
        let runID = UUID()
        activeEpisodeID = episode.episodeID
        activeRunID = runID
        activeSourceFileURL = localFileURL
        activeEngine = engine
        activeCancellationPreservesPartial = false
        activePreservesPriorCompletedTranscript = preservesPriorCompletedTranscript
        priorCompletedTranscriptSnapshot = nil
        if engine == .appleSpeech {
            setIdleTimerDisabled(true)
        }
        activeTask = Task {
            await runTranscription(
                runID: runID,
                episode: episode,
                downloadRecord: downloadRecord,
                localFileURL: localFileURL,
                engine: engine,
                modelIdentity: modelIdentity,
                languageCode: languageCode,
                runLanguageCode: runLanguageCode ?? languageCode,
                initialComputeProfile: initialComputeProfile,
                modelContext: modelContext
            )
        }
        stateChanges.notify()
        return true
    }

    func cancelTranscription(episodeID: String, modelContext: ModelContext) {
        guard activeEpisodeID == episodeID else {
            return
        }
        activeCancellationPreservesPartial = false
        activeTask?.cancel()
    }

    func interruptActiveJob(modelContext: ModelContext) {
        guard activeTask != nil else {
            return
        }
        activeCancellationPreservesPartial = true
        activeTask?.cancel()
    }

    func deleteTranscript(episodeID: String, modelContext: ModelContext) {
        if activeEpisodeID == episodeID {
            activeCancellationPreservesPartial = false
            activeTask?.cancel()
        }

        do {
            if let snapshot = takePriorCompletedTranscriptSnapshot(for: episodeID) {
                try fileStore.delete(relativePath: snapshot.transcriptRelativePath)
            }
            let matchingRecords = try fetchRecords(episodeID: episodeID, modelContext: modelContext)
            for record in matchingRecords {
                try fileStore.delete(relativePath: record.transcriptRelativePath)
                modelContext.delete(record)
            }
            try modelContext.save()
            clearTransientProgress(episodeID: episodeID)
            try reload(modelContext: modelContext)
            clearFailure(episodeID: episodeID)
            notifyEpisodeStateChanged(episodeID)
        } catch {
            recordFailure(error, episodeID: episodeID)
        }
    }

    func handleDownloadDeletion(
        _ record: EpisodeDownloadRecord,
        localFileURL: URL?,
        modelContext: ModelContext
    ) {
        if activeEpisodeID == record.episodeID,
           localFileURL == nil || activeSourceFileURL == localFileURL {
            activeCancellationPreservesPartial = false
            activeTask?.cancel()
        }

        do {
            try deletePartialRecords(
                episodeID: record.episodeID,
                sourceAudioURL: record.sourceAudioURL,
                modelContext: modelContext
            )
            clearFailure(episodeID: record.episodeID)
        } catch {
            recordFailure(error, episodeID: record.episodeID)
        }
    }

    func handleAllDownloadsDeleted(modelContext: ModelContext) {
        if activeTask != nil {
            activeCancellationPreservesPartial = false
            activeTask?.cancel()
        }

        do {
            let partialRecords = try fetchRecords(modelContext: modelContext)
                .filter { $0.state != .completed }
            for record in partialRecords {
                try fileStore.delete(relativePath: record.transcriptRelativePath)
                modelContext.delete(record)
            }
            try modelContext.save()
            try reload(modelContext: modelContext)
            clearFailure()
        } catch {
            recordFailure(error)
        }
    }

    func deleteTranscripts(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let records = try fetchRecords(forPodcastID: podcastID, modelContext: modelContext)
        for record in records {
            if activeEpisodeID == record.episodeID {
                activeCancellationPreservesPartial = false
                activeTask?.cancel()
            }
            try fileStore.delete(relativePath: record.transcriptRelativePath)
            modelContext.delete(record)
        }
        if !records.isEmpty {
            try modelContext.save()
        }
        try reload(modelContext: modelContext)
        clearFailure()
        for record in records {
            notifyEpisodeStateChanged(record.episodeID)
        }
    }

    func nukeAllTranscripts(modelContext: ModelContext) async throws {
        await unloadRuntime()
        priorCompletedTranscriptSnapshot = nil
        progressByEpisodeID.removeAll()
        lastProgressPublicationByEpisodeID.removeAll()

        for record in try fetchRecords(modelContext: modelContext) {
            modelContext.delete(record)
        }
        try fileStore.deleteAllTranscripts()
        try modelContext.save()
        records.removeAll()
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        stateChanges.notify()
    }

    func unloadRuntime() async {
        await cancelActiveJobAndWait(preservesPartial: false)
        await transcriber.unload()
    }

    /// Drain-scoped model retention (whisper-perf E1) — forwarded from the
    /// ad-free-pass queue coordinator around one queue drain.
    func beginModelRetentionDrain() {
        transcriber.beginDrainRetention()
    }

    func endModelRetentionDrain() async {
        await transcriber.endDrainRetention()
    }

    private func cancelActiveJobAndWait(preservesPartial: Bool) async {
        guard let activeTask else {
            return
        }

        activeCancellationPreservesPartial = preservesPartial
        activeTask.cancel()
        await activeTask.value
    }

    private func runTranscription(
        runID: UUID,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        engine: EpisodeTranscriptionEngine,
        modelIdentity: EpisodeTranscriptionModelIdentity,
        languageCode: String,
        runLanguageCode: String,
        initialComputeProfile: OpenCastTranscriptionComputeProfile,
        modelContext: ModelContext
    ) async {
        defer {
            clearActiveRun(episodeID: episode.episodeID, runID: runID)
        }

        var workingRelativePath: String?
        var computeProfile = initialComputeProfile
        while true {
            do {
                try await runTranscriptionAttempt(
                    runID: runID,
                    episode: episode,
                    downloadRecord: downloadRecord,
                    localFileURL: localFileURL,
                    engine: engine,
                    modelIdentity: modelIdentity,
                    languageCode: languageCode,
                    runLanguageCode: runLanguageCode,
                    modelContext: modelContext,
                    computeProfile: computeProfile,
                    workingRelativePath: &workingRelativePath
                )
                await transcriber.releaseRunResources()
                guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
                    return
                }
                if activeCancellationPreservesPartial || Task.isCancelled {
                    handleCancellation(
                        episodeID: episode.episodeID,
                        relativePath: workingRelativePath,
                        engine: engine,
                        modelContext: modelContext
                    )
                }
                return
            } catch is CancellationError {
                await transcriber.unload()
                guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
                    return
                }
                handleCancellation(
                    episodeID: episode.episodeID,
                    relativePath: workingRelativePath,
                    engine: engine,
                    modelContext: modelContext
                )
                return
            } catch {
                await transcriber.unload()
                guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
                    return
                }
                if activeCancellationPreservesPartial {
                    handleCancellation(
                        episodeID: episode.episodeID,
                        relativePath: workingRelativePath,
                        engine: engine,
                        modelContext: modelContext
                    )
                    return
                }

                switch handleTranscriptionFailure(
                    episodeID: episode.episodeID,
                    relativePath: workingRelativePath,
                    error: error,
                    engine: engine,
                    attemptedComputeProfile: computeProfile,
                    modelContext: modelContext
                ) {
                case .retry(let nextProfile):
                    computeProfile = nextProfile
                    continue
                case .finish:
                    return
                }
            }
        }
    }

    private func runTranscriptionAttempt(
        runID: UUID,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        engine: EpisodeTranscriptionEngine,
        modelIdentity: EpisodeTranscriptionModelIdentity,
        languageCode: String,
        runLanguageCode: String,
        modelContext: ModelContext,
        computeProfile: OpenCastTranscriptionComputeProfile,
        workingRelativePath: inout String?
    ) async throws {
        let identity = try await EpisodeTranscriptionSourceIdentity.load(from: localFileURL)
        try Task.checkCancellation()
        guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
            throw CancellationError()
        }
        let audioDuration = sanitizedDuration(identity.duration ?? episode.duration)
        guard let audioDuration else {
            throw EpisodeTranscriptionError.invalidAudioDuration
        }

        let existingRecord = try fetchStoredRecord(episodeID: episode.episodeID, modelContext: modelContext)
        if activePreservesPriorCompletedTranscript,
           priorCompletedTranscriptSnapshot == nil,
           let existingRecord,
           existingRecord.state == .completed,
           fileStore.documentExists(relativePath: existingRecord.transcriptRelativePath) {
            priorCompletedTranscriptSnapshot = PriorCompletedTranscriptSnapshot(record: existingRecord)
        }
        let resumeState = await resumableWhisperState(
            from: existingRecord,
            identity: identity,
            modelIdentity: modelIdentity,
            engine: engine
        )
        try Task.checkCancellation()
        guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
            throw CancellationError()
        }
        let resumeStart = resumeState?.start
        let baseDocument = resumeState?.document
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: identity.sha256,
            modelIdentifier: modelIdentity.modelIdentifier,
            modelVersion: modelIdentity.version,
            modelTreeSHA256: modelIdentity.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, fingerprint: fingerprint)
        workingRelativePath = relativePath

        let record = try upsertRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: downloadRecord.sourceAudioURL,
            sourceFileByteCount: identity.byteCount,
            sourceFileSHA256: identity.sha256,
            modelIdentity: modelIdentity,
            languageCode: languageCode,
            state: .running,
            audioDuration: audioDuration,
            completedDuration: resumeStart ?? 0,
            checkpointCount: baseDocument?.checkpoints.count ?? 0,
            transcriptRelativePath: relativePath,
            errorMessage: nil,
            modelContext: modelContext
        )
        try commit(episodeID: episode.episodeID, modelContext: modelContext, resort: true)

        let request = EpisodeTranscriptionRunRequest(
            engine: engine,
            audioFileURL: localFileURL,
            languageCode: runLanguageCode,
            resumeStart: resumeStart,
            sourceAudioURL: record.sourceAudioURL,
            sourceFileByteCount: identity.byteCount,
            sourceFileSHA256: identity.sha256,
            modelIdentifier: modelIdentity.modelIdentifier,
            modelVersion: modelIdentity.version,
            modelTreeSHA256: modelIdentity.treeSHA256,
            computeProfile: computeProfile
        )
        AdFreePassBackgroundRunLog.record(
            "transcription starting engine=\(engine.rawValue) model=\(modelIdentity.modelIdentifier) version=\(modelIdentity.version) language=\(languageCode) resume=\((resumeStart ?? 0).backgroundLogSeconds) audio=\(audioDuration.backgroundLogSeconds) sourceBytes=\(identity.byteCount) sourceSHA=\(identity.sha256)"
        )

        for try await event in transcriber.transcribe(request) {
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
                throw CancellationError()
            }
            switch event {
            case .progress(let progress):
                // Progress stays transient and rate-limited: Apple Speech emits
                // events every 40–100ms, and dirtying the record per event both
                // autosaves churn and invalidates every observer at event rate.
                // Checkpoints persist completedDuration durably.
                publishProgress(progress, episodeID: episode.episodeID)
            case .checkpoint(let checkpoint):
                try await persistCheckpoint(
                    checkpoint,
                    baseDocument: baseDocument,
                    record: record,
                    relativePath: relativePath,
                    runID: runID,
                    modelContext: modelContext
                )
            case .finished(let result):
                try await persistFinalResult(
                    result,
                    baseDocument: baseDocument,
                    record: record,
                    relativePath: relativePath,
                    runID: runID,
                    modelContext: modelContext
                )
            }
        }
    }

    private enum TranscriptionFailureAction {
        case retry(OpenCastTranscriptionComputeProfile)
        case finish
    }

    private func handleTranscriptionFailure(
        episodeID: String,
        relativePath: String?,
        error: any Error,
        engine: EpisodeTranscriptionEngine,
        attemptedComputeProfile: OpenCastTranscriptionComputeProfile,
        modelContext: ModelContext
    ) -> TranscriptionFailureAction {
        let classification = TranscriptionFailureClassifier.classify(
            error,
            environment: failureEnvironment()
        )

        switch classification {
        case .cancelled:
            handleCancellation(
                episodeID: episodeID,
                relativePath: relativePath,
                engine: engine,
                modelContext: modelContext
            )
            return .finish
        case .environmentalCompute:
            return handleEnvironmentalComputeFailure(
                episodeID: episodeID,
                relativePath: relativePath,
                error: error,
                engine: engine,
                attemptedComputeProfile: attemptedComputeProfile,
                modelContext: modelContext
            )
        case .environmentalStorage:
            return handleEnvironmentalStorageFailure(
                episodeID: episodeID,
                relativePath: relativePath,
                error: error,
                engine: engine,
                modelContext: modelContext
            )
        case .failed:
            markFailed(
                episodeID: episodeID,
                relativePath: relativePath,
                error: error,
                modelContext: modelContext
            )
            return .finish
        }
    }

    /// Whisper-perf G2: disk exhaustion during the audio spill. A lower
    /// compute rung cannot free storage, so skip the retry ladder and
    /// interrupt (resumable) directly.
    private func handleEnvironmentalStorageFailure(
        episodeID: String,
        relativePath: String?,
        error: any Error,
        engine: EpisodeTranscriptionEngine,
        modelContext: ModelContext
    ) -> TranscriptionFailureAction {
        do {
            guard let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                return .finish
            }
            recordFailureDiagnostics(error: error, record: record)
            AdFreePassBackgroundRunLog.record(
                "transcription environmental storage failure action=interrupted episodeID=\(episodeID) completed=\(record.completedDuration.backgroundLogSeconds) checkpoints=\(record.checkpointCount)"
            )
            markInterruptedAfterEnvironmentalFailure(
                record: record,
                relativePath: relativePath,
                engine: engine,
                modelContext: modelContext
            )
            return .finish
        } catch {
            recordFailure(error, episodeID: episodeID)
            return .finish
        }
    }

    private func handleEnvironmentalComputeFailure(
        episodeID: String,
        relativePath: String?,
        error: any Error,
        engine: EpisodeTranscriptionEngine,
        attemptedComputeProfile: OpenCastTranscriptionComputeProfile,
        modelContext: ModelContext
    ) -> TranscriptionFailureAction {
        do {
            guard let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                return .finish
            }
            recordFailureDiagnostics(error: error, record: record)

            // The CoreML CPU-only retry is a whisper mechanism; Apple runs
            // restart from zero instead (decision 6).
            guard engine == .whisper, attemptedComputeProfile != .cpuOnly else {
                markInterruptedAfterEnvironmentalFailure(
                    record: record,
                    relativePath: relativePath,
                    engine: engine,
                    modelContext: modelContext
                )
                return .finish
            }

            AdFreePassBackgroundRunLog.record(
                "transcription environmental compute failure action=retryCpuOnly episodeID=\(episodeID) attemptedProfile=\(attemptedComputeProfile.logDescription) completed=\(record.completedDuration.backgroundLogSeconds) checkpoints=\(record.checkpointCount)"
            )
            lastEnvironmentalComputeFallbackEpisodeID = episodeID
            return .retry(.cpuOnly)
        } catch {
            recordFailure(error, episodeID: episodeID)
            return .finish
        }
    }

    private func persistCheckpoint(
        _ checkpoint: OpenCastLongFormTranscriptionCheckpoint,
        baseDocument: EpisodeTranscriptDocument?,
        record: EpisodeTranscriptRecord,
        relativePath: String,
        runID: UUID,
        modelContext: ModelContext
    ) async throws {
        let prefixSegments = baseSegments(from: baseDocument, resumeStart: record.completedDuration)
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(
            prefixSegments + checkpoint.segments
        )
        let priorCompletedDuration = record.completedDuration
        let checkpointCompletedDuration = max(checkpoint.completedDuration, segments.map(\.end).max() ?? 0)
        let completedDuration = min(max(priorCompletedDuration, checkpointCompletedDuration), record.audioDuration)
        let checkpoints = (baseDocument?.checkpoints ?? []) + [
            EpisodeTranscriptCheckpoint(
                id: (baseDocument?.checkpoints.count ?? 0) + checkpoint.index,
                completedDuration: completedDuration,
                segmentCount: segments.count,
                createdAt: .now
            )
        ]
        let document = makeDocument(
            record: record,
            checkpoints: checkpoints,
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: baseDocument?.timings ?? EpisodeTranscriptTimings(),
            createdAt: baseDocument?.createdAt ?? record.createdAt
        )
        try await fileStore.writeOffCaller(document, relativePath: relativePath)
        try Task.checkCancellation()
        guard ownsActiveRun(episodeID: record.episodeID, runID: runID) else {
            throw CancellationError()
        }

        record.state = .running
        record.completedDuration = min(completedDuration, record.audioDuration)
        record.checkpointCount = checkpoints.count
        record.errorMessage = nil
        record.updatedAt = .now
        try commit(episodeID: record.episodeID, modelContext: modelContext)
    }

    private func persistFinalResult(
        _ result: OpenCastTranscriptionResult,
        baseDocument: EpisodeTranscriptDocument?,
        record: EpisodeTranscriptRecord,
        relativePath: String,
        runID: UUID,
        modelContext: ModelContext
    ) async throws {
        let prefixSegments = baseSegments(from: baseDocument, resumeStart: record.completedDuration)
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(
            prefixSegments + result.segments
        )
        let checkpoints = baseDocument?.checkpoints ?? []
        let document = makeDocument(
            record: record,
            checkpoints: checkpoints,
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(resultTimings: result.timings),
            createdAt: baseDocument?.createdAt ?? record.createdAt
        )
        try await fileStore.writeOffCaller(document, relativePath: relativePath)
        try Task.checkCancellation()
        guard ownsActiveRun(episodeID: record.episodeID, runID: runID) else {
            throw CancellationError()
        }

        record.state = .completed
        record.completedDuration = record.audioDuration
        record.checkpointCount = checkpoints.count
        record.errorMessage = nil
        record.updatedAt = .now
        try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        if let snapshot = takePriorCompletedTranscriptSnapshot(for: record.episodeID),
           snapshot.transcriptRelativePath != relativePath {
            // The improved document supersedes the preserved one; the completed
            // improve must not fail over a cleanup error.
            try? fileStore.delete(relativePath: snapshot.transcriptRelativePath)
        }
        AdFreePassBackgroundRunLog.record(
            "transcription completed model=\(record.modelIdentifier) version=\(record.modelVersion) audio=\(result.timings.audioDuration.backgroundLogSeconds) transcription=\(result.timings.transcription.backgroundLogSeconds) fullPipeline=\(result.timings.fullPipeline.backgroundLogSeconds) rtf=\(result.timings.realTimeFactor.backgroundLogNumber) segments=\(segments.count) checkpoints=\(checkpoints.count) relativePath=\(relativePath)"
        )
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
    }

    /// Narrow import path for remotely produced transcripts. Writes the
    /// schema-3 document atomically at its remote fingerprint, upserts the
    /// record with explicit remote provenance, preserves any prior completed
    /// transcript until the new document has committed, and notifies the
    /// existing UI. Remote jobs never touch the local run loop.
    func importRemoteTranscript(
        _ document: EpisodeTranscriptDocument,
        modelContext: ModelContext
    ) async throws {
        guard activeEngine(for: document.episodeID) == nil else {
            throw RemoteTranscriptImportError.localTranscriptionActive
        }

        let fingerprint = fileStore.remoteFingerprint(
            sourceFileSHA256: document.sourceFileSHA256,
            provider: EpisodeRemoteTranscriptMapper.provider,
            providerModelIdentifier: document.providerModelIdentifier ?? document.modelIdentifier,
            servingContractVersion: document.remoteServingContractVersion ?? document.modelVersion,
            pipelineVersion: document.remotePipelineVersion ?? ""
        )
        let relativePath = fileStore.relativePath(
            episodeID: document.episodeID,
            fingerprint: fingerprint
        )
        let priorRecord = try fetchStoredRecord(
            episodeID: document.episodeID,
            modelContext: modelContext
        )
        let priorRelativePath = priorRecord?.state == .completed
            ? priorRecord?.transcriptRelativePath
            : nil

        try await fileStore.writeOffCaller(document, relativePath: relativePath)

        let record = try upsertRecord(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            sourceAudioURL: document.sourceAudioURL,
            sourceFileByteCount: document.sourceFileByteCount,
            sourceFileSHA256: document.sourceFileSHA256,
            modelIdentity: EpisodeTranscriptionModelIdentity(
                modelIdentifier: document.modelIdentifier,
                version: document.modelVersion,
                treeSHA256: document.modelTreeSHA256
            ),
            languageCode: document.languageCode,
            state: .completed,
            audioDuration: document.audioDuration,
            completedDuration: document.audioDuration,
            checkpointCount: 0,
            transcriptRelativePath: relativePath,
            errorMessage: nil,
            modelContext: modelContext
        )
        record.transcriptionEngineRawValue = EpisodeTranscriptEngineProvenance.remoteWhisper.rawValue
        try commit(episodeID: document.episodeID, modelContext: modelContext, resort: true)
        if let priorRelativePath, priorRelativePath != relativePath {
            // The committed remote document supersedes the preserved one; a
            // cleanup failure must not fail the completed import.
            try? fileStore.delete(relativePath: priorRelativePath)
        }
        notifyEpisodeStateChanged(document.episodeID)
    }

    private func makeDocument(
        record: EpisodeTranscriptRecord,
        checkpoints: [EpisodeTranscriptCheckpoint],
        segments: [OpenCastTranscriptSegment],
        text: String,
        timings: EpisodeTranscriptTimings,
        createdAt: Date
    ) -> EpisodeTranscriptDocument {
        EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: record.episodeID,
            podcastID: record.podcastID,
            sourceAudioURL: record.sourceAudioURL,
            sourceFileByteCount: record.sourceFileByteCount,
            sourceFileSHA256: record.sourceFileSHA256,
            modelIdentifier: record.modelIdentifier,
            modelVersion: record.modelVersion,
            modelTreeSHA256: record.modelTreeSHA256,
            languageCode: record.languageCode,
            audioDuration: record.audioDuration,
            checkpoints: checkpoints,
            segments: segments,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            timings: timings,
            createdAt: createdAt,
            updatedAt: .now,
            transcriptionEngine: record.engineProvenance.rawValue
        )
    }

    private func handleCancellation(
        episodeID: String,
        relativePath: String?,
        engine: EpisodeTranscriptionEngine,
        modelContext: ModelContext
    ) {
        do {
            guard let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                return
            }
            guard record.state != .completed else {
                return
            }

            if let snapshot = takePriorCompletedTranscriptSnapshot(for: episodeID) {
                try restore(
                    snapshot,
                    onto: record,
                    discardingPartialAt: relativePath ?? record.transcriptRelativePath,
                    modelContext: modelContext
                )
                if activeCancellationPreservesPartial, engine == .appleSpeech {
                    onAppleSpeechRunInterrupted?(episodeID, true)
                }
                return
            }

            if activeCancellationPreservesPartial {
                record.state = .interrupted
                record.errorMessage = nil
            } else {
                try fileStore.delete(relativePath: relativePath ?? record.transcriptRelativePath)
                record.state = .cancelled
                record.transcriptRelativePath = nil
                record.checkpointCount = 0
                record.completedDuration = 0
                record.errorMessage = nil
            }
            record.updatedAt = .now
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            clearFailure(episodeID: episodeID)
            if activeCancellationPreservesPartial, engine == .appleSpeech {
                onAppleSpeechRunInterrupted?(episodeID, false)
            }
        } catch {
            recordFailure(error, episodeID: episodeID)
        }
    }

    private func markFailed(
        episodeID: String,
        relativePath: String?,
        error: Error,
        modelContext: ModelContext
    ) {
        do {
            guard let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                return
            }
            recordFailureDiagnostics(error: error, record: record)
            if let snapshot = takePriorCompletedTranscriptSnapshot(for: episodeID) {
                // The improve attempt failed; the prior transcript comes back
                // while the failure stays surfaced for the improve banner.
                try restore(
                    snapshot,
                    onto: record,
                    discardingPartialAt: relativePath ?? record.transcriptRelativePath,
                    modelContext: modelContext
                )
                recordFailure(error, episodeID: episodeID)
                return
            }
            record.state = .failed
            record.errorMessage = error.localizedDescription
            record.transcriptRelativePath = relativePath ?? record.transcriptRelativePath
            record.updatedAt = .now
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            recordFailure(error, episodeID: episodeID)
        } catch {
            recordFailure(error, episodeID: episodeID)
        }
    }

    private func markInterruptedAfterEnvironmentalFailure(
        record: EpisodeTranscriptRecord,
        relativePath: String?,
        engine: EpisodeTranscriptionEngine,
        modelContext: ModelContext
    ) {
        do {
            if let snapshot = takePriorCompletedTranscriptSnapshot(for: record.episodeID) {
                try restore(
                    snapshot,
                    onto: record,
                    discardingPartialAt: relativePath ?? record.transcriptRelativePath,
                    modelContext: modelContext
                )
                AdFreePassBackgroundRunLog.record(
                    "transcription environmental compute failure action=restoredPriorCompleted episodeID=\(record.episodeID)"
                )
                if engine == .appleSpeech {
                    onAppleSpeechRunInterrupted?(record.episodeID, true)
                }
                return
            }
            record.state = .interrupted
            record.errorMessage = Self.environmentalInterruptMessage
            record.transcriptRelativePath = relativePath ?? record.transcriptRelativePath
            record.updatedAt = .now
            try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
            clearFailure(episodeID: record.episodeID)
            if engine == .appleSpeech {
                onAppleSpeechRunInterrupted?(record.episodeID, false)
            }
            AdFreePassBackgroundRunLog.record(
                "transcription environmental compute failure action=interrupted episodeID=\(record.episodeID) completed=\(record.completedDuration.backgroundLogSeconds) checkpoints=\(record.checkpointCount)"
            )
        } catch {
            recordFailure(error, episodeID: record.episodeID)
        }
    }

    private func takePriorCompletedTranscriptSnapshot(for episodeID: String) -> PriorCompletedTranscriptSnapshot? {
        guard let snapshot = priorCompletedTranscriptSnapshot, snapshot.episodeID == episodeID else {
            return nil
        }
        priorCompletedTranscriptSnapshot = nil
        return snapshot
    }

    private func clearActiveRun(episodeID: String, runID: UUID) {
        guard ownsActiveRun(episodeID: episodeID, runID: runID) else {
            return
        }

        setIdleTimerDisabled(false)
        activeTask = nil
        activeEpisodeID = nil
        activeRunID = nil
        activeSourceFileURL = nil
        activeEngine = nil
        activeCancellationPreservesPartial = false
        activePreservesPriorCompletedTranscript = false
        priorCompletedTranscriptSnapshot = nil
        clearTransientProgress(episodeID: episodeID)
        stateChanges.notify()
    }

    /// Aborted improve runs put the app back exactly as before the tap: the
    /// partial replacement document is discarded and the record is rewound to
    /// the preserved completed transcript.
    private func restore(
        _ snapshot: PriorCompletedTranscriptSnapshot,
        onto record: EpisodeTranscriptRecord,
        discardingPartialAt relativePath: String?,
        modelContext: ModelContext
    ) throws {
        if let relativePath, relativePath != snapshot.transcriptRelativePath {
            try fileStore.delete(relativePath: relativePath)
        }
        snapshot.restore(onto: record)
        record.updatedAt = .now
        try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        clearFailure(episodeID: record.episodeID)
        AdFreePassBackgroundRunLog.record(
            "transcription restored prior completed transcript episodeID=\(record.episodeID) model=\(record.modelIdentifier)"
        )
    }

    private func recordFailureDiagnostics(error: Error, record: EpisodeTranscriptRecord) {
        let nsError = error as NSError
        AdFreePassBackgroundRunLog.record(
            "transcription failed episodeID=\(record.episodeID) state=\(record.state) completed=\(record.completedDuration.backgroundLogSeconds) audio=\(record.audioDuration.backgroundLogSeconds) checkpoints=\(record.checkpointCount) errorDomain=\(nsError.domain) errorCode=\(nsError.code) description=\(nsError.localizedDescription)"
        )
        AdFreePassBackgroundEnvironmentSnapshot.record(reason: "transcription-failed")
    }

    private func reconcile(modelContext: ModelContext) throws {
        let fetchedRecords = try fetchRecords(modelContext: modelContext)
        var changed = false

        for record in fetchedRecords {
            switch record.state {
            case .queued, .running:
                record.state = .interrupted
                record.updatedAt = .now
                changed = true
            case .completed:
                guard fileStore.documentExists(relativePath: record.transcriptRelativePath) else {
                    record.state = .failed
                    record.errorMessage = "Transcript document is missing."
                    record.updatedAt = .now
                    changed = true
                    continue
                }
            case .failed, .cancelled, .interrupted:
                break
            }
        }

        if changed {
            try modelContext.save()
        }
    }

    private func validate(
        downloadRecord: EpisodeDownloadRecord,
        episode: EpisodeListItemSnapshot,
        localFileURL: URL
    ) throws {
        guard downloadRecord.episodeID == episode.episodeID,
              downloadRecord.podcastID == episode.podcastID
        else {
            throw EpisodeTranscriptionError.mismatchedDownloadRecord
        }
        guard downloadRecord.state == .completed else {
            throw EpisodeTranscriptionError.downloadNotComplete
        }
        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw EpisodeTranscriptionError.missingDownloadedFile
        }
    }

    private func resumableWhisperState(
        from record: EpisodeTranscriptRecord?,
        identity: EpisodeTranscriptionSourceIdentity,
        modelIdentity: EpisodeTranscriptionModelIdentity,
        engine: EpisodeTranscriptionEngine
    ) async -> (start: TimeInterval, document: EpisodeTranscriptDocument)? {
        // Apple Speech restarts from zero (decision 6); resume is a
        // whisper-checkpoint mechanism.
        guard engine == .whisper,
              let record,
              hasWhisperResumeMetadata(record),
              record.sourceFileByteCount == identity.byteCount,
              record.sourceFileSHA256 == identity.sha256,
              recordMatches(record, identity: modelIdentity),
              let relativePath = record.transcriptRelativePath,
              let document = try? await fileStore.readOffCaller(relativePath: relativePath)
        else {
            return nil
        }
        guard document.schemaVersion > 0,
              document.schemaVersion <= EpisodeTranscriptDocument.currentSchemaVersion,
              document.episodeID == record.episodeID,
              document.podcastID == record.podcastID,
              document.sourceAudioURL == record.sourceAudioURL,
              document.sourceFileByteCount == record.sourceFileByteCount,
              document.sourceFileSHA256 == record.sourceFileSHA256,
              document.modelIdentifier == record.modelIdentifier,
              document.modelVersion == record.modelVersion,
              document.modelTreeSHA256 == record.modelTreeSHA256,
              document.languageCode == record.languageCode,
              document.audioDuration == record.audioDuration,
              document.checkpoints.count == record.checkpointCount,
              let checkpoint = document.checkpoints.last,
              checkpoint.completedDuration.isFinite,
              checkpoint.completedDuration > 0,
              checkpoint.completedDuration < record.audioDuration,
              checkpoint.completedDuration <= record.completedDuration,
              checkpoint.segmentCount == document.segments.count,
              document.checkpoints.allSatisfy({
                  $0.completedDuration <= checkpoint.completedDuration
              })
        else {
            return nil
        }
        return (checkpoint.completedDuration, document)
    }

    private func hasWhisperResumeMetadata(_ record: EpisodeTranscriptRecord) -> Bool {
        guard record.state == .interrupted || record.state == .running,
              record.completedDuration > 0,
              record.checkpointCount > 0,
              OpenCastWhisperModel.allCases.contains(where: {
                  $0.rawValue == record.modelIdentifier
              })
        else {
            return false
        }
        return fileStore.documentExists(relativePath: record.transcriptRelativePath)
    }

    private func baseSegments(
        from document: EpisodeTranscriptDocument?,
        resumeStart: TimeInterval
    ) -> [OpenCastTranscriptSegment] {
        guard let document else {
            return []
        }
        return document.segments.filter { $0.end <= resumeStart + 0.001 }
    }

    private func deletePartialRecords(
        episodeID: String,
        sourceAudioURL: String,
        modelContext: ModelContext
    ) throws {
        let records = try fetchRecords(episodeID: episodeID, modelContext: modelContext)
            .filter { $0.state != .completed && $0.sourceAudioURL == sourceAudioURL }
        for record in records {
            try fileStore.delete(relativePath: record.transcriptRelativePath)
            modelContext.delete(record)
        }
        if !records.isEmpty {
            try modelContext.save()
        }
        try reload(modelContext: modelContext)
        notifyEpisodeStateChanged(episodeID)
    }

    @discardableResult
    private func upsertRecord(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: String,
        sourceFileByteCount: Int64 = 0,
        sourceFileSHA256: String = "",
        modelIdentity: EpisodeTranscriptionModelIdentity? = nil,
        languageCode: String = "en",
        state: EpisodeTranscriptState,
        audioDuration: TimeInterval = 0,
        completedDuration: TimeInterval = 0,
        checkpointCount: Int = 0,
        transcriptRelativePath: String? = nil,
        errorMessage: String? = nil,
        modelContext: ModelContext
    ) throws -> EpisodeTranscriptRecord {
        let matchingRecords = try fetchRecords(episodeID: episodeID, modelContext: modelContext)
        let record: EpisodeTranscriptRecord
        if let existingRecord = matchingRecords.first {
            record = existingRecord
        } else {
            record = EpisodeTranscriptRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                sourceAudioURL: sourceAudioURL
            )
            modelContext.insert(record)
        }

        for duplicateRecord in matchingRecords.dropFirst() {
            try fileStore.delete(relativePath: duplicateRecord.transcriptRelativePath)
            modelContext.delete(duplicateRecord)
        }

        record.podcastID = podcastID
        record.sourceAudioURL = sourceAudioURL
        record.sourceFileByteCount = sourceFileByteCount
        record.sourceFileSHA256 = sourceFileSHA256
        record.languageCode = languageCode
        record.state = state
        record.audioDuration = audioDuration
        record.completedDuration = completedDuration
        record.checkpointCount = checkpointCount
        record.transcriptRelativePath = transcriptRelativePath
        record.errorMessage = errorMessage
        if let modelIdentity {
            record.modelIdentifier = modelIdentity.modelIdentifier
            record.modelVersion = modelIdentity.version
            record.modelTreeSHA256 = modelIdentity.treeSHA256
        }
        record.updatedAt = .now
        return record
    }

    private func commit(
        episodeID: String,
        modelContext: ModelContext,
        resort: Bool = false
    ) throws {
        try modelContext.save()
        if let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) {
            updateLoadedRecord(record, resort: resort)
        } else {
            records.removeAll { $0.episodeID == episodeID }
            notifyEpisodeStateChanged(episodeID)
        }
    }

    private func updateLoadedRecord(_ record: EpisodeTranscriptRecord, resort: Bool = false) {
        if let index = records.firstIndex(where: { $0.episodeID == record.episodeID }) {
            records[index] = record
        } else {
            records.append(record)
        }

        if resort {
            records.sort { $0.updatedAt > $1.updatedAt }
        }
        notifyEpisodeStateChanged(record.episodeID)
    }

    private func reload(modelContext: ModelContext) throws {
        records = try fetchRecords(modelContext: modelContext)
    }

    private func fetchStoredRecord(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> EpisodeTranscriptRecord? {
        let targetEpisodeID = episodeID
        var descriptor = FetchDescriptor<EpisodeTranscriptRecord>(
            predicate: #Predicate { record in
                record.episodeID == targetEpisodeID
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRecords(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeTranscriptRecord] {
        let targetEpisodeID = episodeID
        return try modelContext.fetch(
            FetchDescriptor<EpisodeTranscriptRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func fetchRecords(
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeTranscriptRecord] {
        let targetPodcastID = podcastID
        return try modelContext.fetch(
            FetchDescriptor<EpisodeTranscriptRecord>(
                predicate: #Predicate { record in
                    record.podcastID == targetPodcastID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func fetchRecords(modelContext: ModelContext) throws -> [EpisodeTranscriptRecord] {
        try modelContext.fetch(
            FetchDescriptor<EpisodeTranscriptRecord>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func recordFailure(_ error: Error, episodeID: String? = nil) {
        lastErrorMessage = error.localizedDescription
        lastErrorEpisodeID = episodeID
        stateChanges.notify()
    }

    private func clearFailure(episodeID: String? = nil) {
        guard episodeID == nil || lastErrorEpisodeID == nil || lastErrorEpisodeID == episodeID else {
            return
        }
        let hadFailure = lastErrorMessage != nil || lastErrorEpisodeID != nil
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        if hadFailure {
            stateChanges.notify()
        }
    }

    private func notifyEpisodeStateChanged(_ episodeID: String) {
        stateChanges.notify()
        onEpisodeStateChanged?(episodeID)
    }

    private static let minimumProgressPublicationInterval: TimeInterval = 0.5

    private func publishProgress(_ progress: EpisodeTranscriptionProgress, episodeID: String) {
        let now = Date.now
        if let lastPublishedAt = lastProgressPublicationByEpisodeID[episodeID],
           now.timeIntervalSince(lastPublishedAt) < Self.minimumProgressPublicationInterval {
            return
        }

        lastProgressPublicationByEpisodeID[episodeID] = now
        progressByEpisodeID[episodeID] = progress
        notifyEpisodeStateChanged(episodeID)
    }

    private func clearTransientProgress(episodeID: String) {
        progressByEpisodeID[episodeID] = nil
        lastProgressPublicationByEpisodeID[episodeID] = nil
    }

    private func ownsActiveRun(episodeID: String, runID: UUID) -> Bool {
        activeEpisodeID == episodeID && activeRunID == runID
    }

    private func recordMatches(
        _ record: EpisodeTranscriptRecord,
        identity: EpisodeTranscriptionModelIdentity?
    ) -> Bool {
        guard let identity else {
            return true
        }

        return record.modelIdentifier == identity.modelIdentifier
            && record.modelVersion == identity.version
            && record.modelTreeSHA256 == identity.treeSHA256
    }

    private func progress(from record: EpisodeTranscriptRecord?) -> EpisodeTranscriptionProgress {
        EpisodeTranscriptionProgress(
            audioDuration: record?.audioDuration ?? 0,
            completedDuration: record?.completedDuration ?? 0,
            checkpointCount: record?.checkpointCount ?? 0
        )
    }

    private func sanitizedDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }
}

/// In-memory image of a completed transcript record taken before an improve
/// run rewrites the single per-episode record in place. Lost on force-quit
/// (documented edge: the record then points at the partial replacement and
/// the user regenerates).
private struct PriorCompletedTranscriptSnapshot {
    let episodeID: String
    let modelIdentifier: String
    let modelVersion: String
    let modelTreeSHA256: String
    let languageCode: String
    let transcriptRelativePath: String?
    let sourceAudioURL: String
    let sourceFileByteCount: Int64
    let sourceFileSHA256: String
    let audioDuration: TimeInterval
    let completedDuration: TimeInterval
    let checkpointCount: Int

    init(record: EpisodeTranscriptRecord) {
        episodeID = record.episodeID
        modelIdentifier = record.modelIdentifier
        modelVersion = record.modelVersion
        modelTreeSHA256 = record.modelTreeSHA256
        languageCode = record.languageCode
        transcriptRelativePath = record.transcriptRelativePath
        sourceAudioURL = record.sourceAudioURL
        sourceFileByteCount = record.sourceFileByteCount
        sourceFileSHA256 = record.sourceFileSHA256
        audioDuration = record.audioDuration
        completedDuration = record.completedDuration
        checkpointCount = record.checkpointCount
    }

    func restore(onto record: EpisodeTranscriptRecord) {
        record.modelIdentifier = modelIdentifier
        record.modelVersion = modelVersion
        record.modelTreeSHA256 = modelTreeSHA256
        record.languageCode = languageCode
        record.transcriptRelativePath = transcriptRelativePath
        record.sourceAudioURL = sourceAudioURL
        record.sourceFileByteCount = sourceFileByteCount
        record.sourceFileSHA256 = sourceFileSHA256
        record.audioDuration = audioDuration
        record.completedDuration = completedDuration
        record.checkpointCount = checkpointCount
        record.state = .completed
        record.errorMessage = nil
    }
}
