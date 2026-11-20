import Foundation
import Observation
import OpenCastCore
import OpenCastTranscription
import SwiftData
import UIKit

@Observable
final class EpisodeTranscriptionStore {
    static let environmentalInterruptMessage = "Paused in background - will resume."

    private(set) var records: [EpisodeTranscriptRecord] = [] {
        didSet {
            recordsRevision &+= 1
            recordsByEpisodeID = Dictionary(
                records.map { ($0.episodeID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @ObservationIgnored private var recordsByEpisodeID: [String: EpisodeTranscriptRecord] = [:]
    // Tracked so `record(for:)` registers a dependency even when it returns nil: a body that saw
    // no record must still invalidate when one appears.
    private var recordsRevision = 0
    // Bumped on every reserve and release: the reservations live in the unobserved work coordinator.
    private var workRevision = 0
    private(set) var progressByEpisodeID: [String: EpisodeTranscriptionProgress] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var activeEpisodeID: String?
    var diagnosticComputeClass: String {
        guard activeEpisodeID != nil else { return "idle" }
        guard activeEngine != .appleSpeech else { return "system-speech" }
        return diagnosticWhisperComputeClass
    }
    private(set) var diagnosticWhisperComputeClass = "background-safe"
    private var lastErrorEpisodeID: String?
    /// Cumulative for this process; diagnostics only.
    private(set) var duplicateRepairCount = 0

    @ObservationIgnored private let transcriber: any EpisodeTranscribing
    @ObservationIgnored private let fileStore: EpisodeTranscriptFileStore
    @ObservationIgnored private let failureEnvironment: @MainActor () -> EpisodeTranscriptionFailureEnvironment
    @ObservationIgnored let workCoordinator: EpisodeTranscriptionWorkCoordinator
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var activeRunID: UUID?
    @ObservationIgnored private var activeSourceFileURL: URL?
    @ObservationIgnored private var activeEngine: EpisodeTranscriptionEngine?
    @ObservationIgnored private var activeCancellationPreservesPartial = false
    @ObservationIgnored private var activeInterruptionHoldsForAutoResume = false
    @ObservationIgnored private var activePriorCompletedTranscriptPolicy = PriorCompletedTranscriptPolicy.discard
    @ObservationIgnored private var priorCompletedTranscriptSnapshot: PriorCompletedTranscriptSnapshot?
    /// The run may still be unwinding after a restore ended it; nothing it does may write again.
    @ObservationIgnored private var activeRunEndedByRestore = false
    @ObservationIgnored private var replacementStopsByEpisodeID: [String: EpisodeTranscriptionReplacementStop] = [:]
    @ObservationIgnored private let stateChanges = StoreChangeNotifier()
    @ObservationIgnored var episodeSearchIndexStore: (any LocalLibraryCacheStore)? {
        didSet {
            registerEpisodeSearchIndexRebuildHandler()
            scheduleEpisodeSearchIndexReconciliation()
        }
    }
    /// Reconciliation deletes every indexed transcript `records` lacks, and the index store is
    /// assigned before `load(modelContext:)` runs: only records fetched from the context may drive
    /// it, or every launch would wipe the index.
    @ObservationIgnored private var hasAuthoritativeRecords = false
    /// A superset of the episodes the search index may hold.
    @ObservationIgnored private var searchIndexCandidateEpisodeIDs: Set<String> = []
    @ObservationIgnored private var episodeSearchIndexSyncTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressPublicationByEpisodeID: [String: Date] = [:]
    @ObservationIgnored var onEpisodeStateChanged: ((String) -> Void)?
    @ObservationIgnored var onAppleSpeechRunInterrupted: ((_ episodeID: String, _ restoredPriorTranscript: Bool) -> Void)?
    @ObservationIgnored var setIdleTimerDisabled: (Bool) -> Void = {
        UIApplication.shared.isIdleTimerDisabled = $0
    }
    @ObservationIgnored private(set) var lastEnvironmentalComputeFallbackEpisodeID: String?

    init(
        transcriber: any EpisodeTranscribing = OpenCastEpisodeTranscriber(),
        fileStore: EpisodeTranscriptFileStore = EpisodeTranscriptFileStore(),
        workCoordinator: EpisodeTranscriptionWorkCoordinator = EpisodeTranscriptionWorkCoordinator(),
        failureEnvironment: @escaping @MainActor () -> EpisodeTranscriptionFailureEnvironment = EpisodeTranscriptionFailureEnvironment.current
    ) {
        self.transcriber = transcriber
        self.fileStore = fileStore
        self.workCoordinator = workCoordinator
        self.failureEnvironment = failureEnvironment
    }

    var hasActiveJob: Bool {
        activeTask != nil
    }

    /// Reads the observable `activeEpisodeID` first, so an idle answer
    /// still registers a dependency (`activeTask` is ignored).
    func isActivelyTranscribing(episodeID: String) -> Bool {
        activeEpisodeID == episodeID && activeTask != nil
    }

    func reserveLocalWork(
        for episodeID: String,
        allowsSameEpisodeAttachment: Bool = false
    ) -> Result<EpisodeTranscriptionWorkCoordinator.LocalReservation, EpisodeTranscriptionWorkCoordinator.Conflict> {
        let result: Result<
            EpisodeTranscriptionWorkCoordinator.LocalReservation,
            EpisodeTranscriptionWorkCoordinator.Conflict
        >
        if activeTask != nil {
            guard allowsSameEpisodeAttachment, activeEpisodeID == episodeID else {
                recordFailure(EpisodeTranscriptionError.anotherJobActive, episodeID: episodeID)
                return .failure(.anotherLocalTranscription)
            }
            result = workCoordinator.joinLocal(episodeID: episodeID)
        } else {
            result = workCoordinator.reserveLocal(episodeID: episodeID)
            if case .failure(let conflict) = result {
                recordFailure(conflict, episodeID: episodeID)
            }
        }
        if case .success = result {
            workRevision &+= 1
        }
        return result
    }

    func releaseLocalWork(_ reservation: EpisodeTranscriptionWorkCoordinator.LocalReservation) {
        workCoordinator.releaseLocal(reservation)
        workRevision &+= 1
    }

    func reserveRemoteWork(
        for episodeID: String
    ) -> Result<EpisodeTranscriptionWorkCoordinator.RemoteReservation, EpisodeTranscriptionWorkCoordinator.Conflict> {
        let result = workCoordinator.reserveRemote(episodeID: episodeID, activeLocalEpisodeID: activeEpisodeID)
        if case .success = result {
            workRevision &+= 1
        }
        return result
    }

    func releaseRemoteWork(_ reservation: EpisodeTranscriptionWorkCoordinator.RemoteReservation) {
        workCoordinator.releaseRemote(reservation)
        workRevision &+= 1
    }

    func holdsWorkReservation(forEpisodeID episodeID: String) -> Bool {
        _ = workRevision
        return workCoordinator.holdsReservation(forEpisodeID: episodeID)
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
        _ = recordsRevision
        return recordsByEpisodeID[episodeID]
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

    func interruptedReplacement(for episodeID: String) -> EpisodeTranscriptionReplacementInterruption? {
        guard case .interrupted(let interruption) = replacementStopsByEpisodeID[episodeID] else {
            return nil
        }
        return interruption
    }

    func consumeInterruptedReplacement(for episodeID: String) -> EpisodeTranscriptionReplacementInterruption? {
        guard let interruption = interruptedReplacement(for: episodeID) else {
            return nil
        }
        replacementStopsByEpisodeID[episodeID] = nil
        return interruption
    }

    func consumeCancelledReplacement(for episodeID: String) -> Bool {
        guard replacementStopsByEpisodeID[episodeID] == .cancelled else {
            return false
        }
        replacementStopsByEpisodeID[episodeID] = nil
        return true
    }

    func document(for episodeID: String) -> EpisodeTranscriptDocument? {
        guard let record = record(for: episodeID),
              let relativePath = record.transcriptRelativePath
        else {
            return nil
        }
        return try? fileStore.read(relativePath: relativePath)
    }

    func importedRemoteDocument(jobID: String, for episodeID: String) -> EpisodeTranscriptDocument? {
        guard record(for: episodeID)?.engineProvenance == .remoteWhisper,
              let document = document(for: episodeID),
              document.remoteJobProvenanceToken == jobID
        else {
            return nil
        }
        return document
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

    func diagnosticsDocumentFileURL(for episodeID: String) -> URL? {
        record(for: episodeID)?.transcriptRelativePath.map(fileStore.fileURL(relativePath:))
    }

    func jobState(
        for episodeID: String,
        downloadRecord: EpisodeDownloadRecord?,
        modelState: TranscriptionModelState,
        modelIdentity: EpisodeTranscriptionModelIdentity? = nil,
        requiresInstalledWhisperModel: Bool = true,
        sourceMatch: EpisodeTranscriptionSourceMatch = .any
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
                // A transcript of other bytes falls through to the download
                // and model checks: the episode is ready to transcribe again.
                if sourceMatch.admits(transcriptSourceSHA256: record.sourceFileSHA256) {
                    return .completed(record)
                }
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
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation? = nil,
        modelContext: ModelContext
    ) -> Bool {
        let modelIdentity = EpisodeTranscriptionModelIdentity(summary: modelSummary)
        return startTranscription(
            episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            engine: .whisper,
            modelIdentity: modelIdentity,
            languageCode: "en",
            localReservation: localReservation,
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
        priorCompletedTranscript: PriorCompletedTranscriptPolicy = .discard,
        priority: TaskPriority? = nil,
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation? = nil,
        modelContext: ModelContext
    ) -> Bool {
        if let conflict = workCoordinator.localStartConflict(
            episodeID: episode.episodeID,
            reservation: localReservation
        ) {
            recordFailure(conflict, episodeID: episode.episodeID)
            return false
        }
        if let activeTask,
           !(activeEpisodeID == episode.episodeID && activeTask.isCancelled) {
            recordFailure(EpisodeTranscriptionError.anotherJobActive, episodeID: episode.episodeID)
            return false
        }

        do {
            try validate(downloadRecord: downloadRecord, episode: episode, localFileURL: localFileURL)
            if activeTask != nil {
                // This episode's cancelled run has not unwound yet, and once
                // this run owns the episode it can restore nothing.
                try restorePriorCompletedTranscriptEndingActiveRun(
                    episodeID: episode.episodeID,
                    keepsInterruptedPartial: true,
                    modelContext: modelContext
                )
            }
        } catch {
            recordFailure(error, episodeID: episode.episodeID)
            return false
        }

        clearFailure(episodeID: episode.episodeID)
        clearTransientProgress(episodeID: episode.episodeID)
        replacementStopsByEpisodeID[episode.episodeID] = nil
        let runID = UUID()
        activeEpisodeID = episode.episodeID
        activeRunID = runID
        activeSourceFileURL = localFileURL
        activeEngine = engine
        activeCancellationPreservesPartial = false
        activeInterruptionHoldsForAutoResume = false
        activePriorCompletedTranscriptPolicy = priorCompletedTranscript
        activeRunEndedByRestore = false
        priorCompletedTranscriptSnapshot = nil
        if engine == .appleSpeech {
            setIdleTimerDisabled(true)
        }
        activeTask = Task(priority: priority) {
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
                priority: priority,
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

    /// With `holdsForAutoResume` the caller resumes the run by itself, so it lands as an
    /// environmental interruption does.
    func interruptActiveJob(modelContext: ModelContext, holdsForAutoResume: Bool = false) {
        guard activeTask != nil else {
            return
        }
        activeCancellationPreservesPartial = true
        activeInterruptionHoldsForAutoResume = holdsForAutoResume
        activeTask?.cancel()
    }

    func deleteTranscript(episodeID: String, modelContext: ModelContext) {
        if activeEpisodeID == episodeID {
            activeCancellationPreservesPartial = false
            activeTask?.cancel()
        }
        replacementStopsByEpisodeID[episodeID] = nil

        do {
            if let snapshot = takePriorCompletedTranscriptSnapshot(for: episodeID) {
                try fileStore.delete(relativePath: snapshot.transcriptRelativePath)
            }
            let matchingRecords = try fetchRecords(episodeID: episodeID, modelContext: modelContext)
            for record in matchingRecords {
                try fileStore.delete(relativePath: record.transcriptRelativePath)
                modelContext.delete(record)
            }
            // The sweep catches files no record names.
            try fileStore.deleteTranscripts(forEpisodeID: episodeID)
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
            try restorePriorCompletedTranscriptEndingActiveRun(
                episodeID: record.episodeID,
                keepsInterruptedPartial: false,
                modelContext: modelContext
            )
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
            try restorePriorCompletedTranscriptEndingActiveRun(
                episodeID: nil,
                keepsInterruptedPartial: false,
                modelContext: modelContext
            )
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

    /// Restores without awaiting the run, which then writes nothing more, so neither its stop
    /// handlers nor a failure in flight can touch the restored record. The partial is kept only
    /// with `keepsInterruptedPartial`, for an interrupted Whisper replacement.
    private func restorePriorCompletedTranscriptEndingActiveRun(
        episodeID: String?,
        keepsInterruptedPartial: Bool,
        modelContext: ModelContext
    ) throws {
        guard let snapshot = priorCompletedTranscriptSnapshot,
              episodeID == nil || snapshot.episodeID == episodeID
        else {
            return
        }
        let keepsPartial = keepsInterruptedPartial
            && activeCancellationPreservesPartial
            && activePriorCompletedTranscriptPolicy == .preserveKeepingInterruptedPartial
            && activeEngine == .whisper
        priorCompletedTranscriptSnapshot = nil
        activeRunEndedByRestore = true
        activeCancellationPreservesPartial = false
        activeTask?.cancel()

        guard let record = try fetchStoredRecord(episodeID: snapshot.episodeID, modelContext: modelContext),
              record.state != .completed
        else {
            return
        }
        try restore(
            snapshot,
            onto: record,
            discardingPartialAt: keepsPartial ? nil : record.transcriptRelativePath,
            modelContext: modelContext
        )
    }

    func deleteTranscripts(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let records = try fetchRecords(forPodcastID: podcastID, modelContext: modelContext)
        for record in records {
            if activeEpisodeID == record.episodeID {
                activeCancellationPreservesPartial = false
                activeTask?.cancel()
            }
            replacementStopsByEpisodeID[record.episodeID] = nil
            try fileStore.delete(relativePath: record.transcriptRelativePath)
            try fileStore.deleteTranscripts(forEpisodeID: record.episodeID)
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

    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        let migratingRecords = try fetchRecords(episodeID: oldEpisodeID, modelContext: modelContext)
        guard !migratingRecords.isEmpty else {
            return
        }

        let targetRecords = try fetchRecords(episodeID: newEpisodeID, modelContext: modelContext)
        try fileStore.migrateTranscripts(fromEpisodeID: oldEpisodeID, to: newEpisodeID)
        let newDirectory = "\(EpisodeTranscriptFileStore.directoryName)/\(fileStore.safeStem(newEpisodeID))"
        for record in migratingRecords {
            record.episodeID = newEpisodeID
            record.podcastID = canonicalPodcastID
            if let relativePath = record.transcriptRelativePath,
               let fileName = relativePath.split(separator: "/").last {
                record.transcriptRelativePath = "\(newDirectory)/\(fileName)"
            }
            // Reconciliation rejects a sidecar whose embedded identity does not match its record. A
            // failed rewrite must not abort a migration whose records are already re-keyed: the stale
            // sidecar stays identity-guarded out of the search index.
            if let relativePath = record.transcriptRelativePath,
               var document = try? fileStore.read(relativePath: relativePath) {
                document.episodeID = newEpisodeID
                document.podcastID = canonicalPodcastID
                try? fileStore.write(document, relativePath: relativePath)
            }
        }
        if !targetRecords.isEmpty {
            duplicateRepairCount += 1
            _ = collapseDuplicateRecords(
                migratingRecords + targetRecords,
                subscribedFeedURLs: EpisodeSidecarRepair.subscribedFeedURLs(
                    modelContext: modelContext
                ),
                modelContext: modelContext
            )
        }

        // A SwiftData refetch need not return the instances `records` holds; reloading makes every
        // lookup see the successor identity.
        try reload(modelContext: modelContext)
        notifyEpisodeStateChanged(newEpisodeID)
    }

    func nukeAllTranscripts(modelContext: ModelContext) async throws {
        await unloadRuntime()
        priorCompletedTranscriptSnapshot = nil
        replacementStopsByEpisodeID.removeAll()
        progressByEpisodeID.removeAll()
        lastProgressPublicationByEpisodeID.removeAll()

        for record in try fetchRecords(modelContext: modelContext) {
            modelContext.delete(record)
        }
        try fileStore.deleteAllTranscripts()
        try modelContext.save()
        records.removeAll()
        hasAuthoritativeRecords = true
        scheduleEpisodeSearchIndexReconciliation()
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        stateChanges.notify()
    }

    func unloadRuntime() async {
        await cancelActiveJobAndWait(preservesPartial: false)
        await transcriber.unload()
    }

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
        activeInterruptionHoldsForAutoResume = false
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
        priority: TaskPriority?,
        modelContext: ModelContext
    ) async {
        defer {
            clearActiveRun(episodeID: episode.episodeID, runID: runID)
        }

        var workingRelativePath: String?
        var computeProfile = initialComputeProfile
        defer { diagnosticWhisperComputeClass = "background-safe" }
        while true {
            diagnosticWhisperComputeClass = switch computeProfile {
            case .backgroundSafe: "background-safe"
            case .cpuOnly: "cpu"
            case .cpuAndNeuralEngine: "neural-engine"
            case .whisperKitDefault: "gpu"
            }
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
                    priority: priority,
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
        priority: TaskPriority?,
        workingRelativePath: inout String?
    ) async throws {
        // Taken before the fallible setup, so a hashing or duration failure
        // restores the prior transcript rather than failing its record.
        if activePriorCompletedTranscriptPolicy != .discard,
           priorCompletedTranscriptSnapshot == nil,
           let priorRecord = try fetchStoredRecord(episodeID: episode.episodeID, modelContext: modelContext),
           priorRecord.state == .completed,
           fileStore.documentExists(relativePath: priorRecord.transcriptRelativePath) {
            priorCompletedTranscriptSnapshot = PriorCompletedTranscriptSnapshot(record: priorRecord)
        }
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
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: identity.sha256,
            modelIdentifier: modelIdentity.modelIdentifier,
            modelVersion: modelIdentity.version,
            modelTreeSHA256: modelIdentity.treeSHA256
        )
        let relativePath = fileStore.relativePath(episodeID: episode.episodeID, fingerprint: fingerprint)
        var resumeState = await resumableWhisperState(
            from: existingRecord,
            identity: identity,
            modelIdentity: modelIdentity,
            engine: engine
        )
        if resumeState == nil,
           activePriorCompletedTranscriptPolicy == .preserveKeepingInterruptedPartial,
           priorCompletedTranscriptSnapshot?.episodeID == episode.episodeID,
           relativePath != existingRecord?.transcriptRelativePath {
            resumeState = await resumableInterruptedReplacementState(
                at: relativePath,
                expecting: WhisperResumeExpectation(
                    episodeID: episode.episodeID,
                    podcastID: episode.podcastID,
                    sourceAudioURL: downloadRecord.sourceAudioURL,
                    sourceFileByteCount: identity.byteCount,
                    sourceFileSHA256: identity.sha256,
                    modelIdentity: modelIdentity,
                    languageCode: languageCode,
                    audioDuration: audioDuration
                ),
                engine: engine
            )
        }
        try Task.checkCancellation()
        guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
            throw CancellationError()
        }
        let resumeStart = resumeState?.start
        let baseDocument = resumeState?.document
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
            computeProfile: computeProfile,
            priority: priority
        )
        AdFreePassBackgroundRunLog.record(
            "transcription starting engine=\(engine.rawValue) model=\(modelIdentity.modelIdentifier) version=\(modelIdentity.version) language=\(languageCode) resume=\((resumeStart ?? 0).backgroundLogSeconds) audio=\(audioDuration.backgroundLogSeconds) sourceBytes=\(identity.byteCount) sourceSHA=\(identity.sha256) priority=\(priority?.description ?? "inherited")"
        )

        // Each rewrite holds every checkpoint so far, so only every Nth is written; the latest skipped
        // one flushes on any exit. Resume stamps advance only with a written document.
        var checkpointEventCount = 0
        var pendingCheckpoint: OpenCastLongFormTranscriptionCheckpoint?
        do {
            for try await event in transcriber.transcribe(request) {
                try Task.checkCancellation()
                guard ownsActiveRun(episodeID: episode.episodeID, runID: runID) else {
                    throw CancellationError()
                }
                switch event {
                case .progress(let progress):
                    // Transient and rate-limited: Apple Speech emits progress every 40 to 100 ms, and
                    // dirtying the record per event would autosave and invalidate every observer.
                    publishProgress(progress, episodeID: episode.episodeID)
                case .checkpoint(let checkpoint):
                    checkpointEventCount += 1
                    if checkpointEventCount % Self.checkpointDocumentWriteInterval == 1 {
                        try await persistCheckpoint(
                            checkpoint,
                            baseDocument: baseDocument,
                            episodeID: episode.episodeID,
                            record: record,
                            relativePath: relativePath,
                            runID: runID,
                            modelContext: modelContext
                        )
                        pendingCheckpoint = nil
                    } else {
                        pendingCheckpoint = checkpoint
                    }
                case .finished(let result):
                    pendingCheckpoint = nil
                    try await persistFinalResult(
                        result,
                        baseDocument: baseDocument,
                        episodeID: episode.episodeID,
                        record: record,
                        relativePath: relativePath,
                        runID: runID,
                        modelContext: modelContext
                    )
                }
            }
            if let checkpoint = pendingCheckpoint {
                try await persistCheckpoint(
                    checkpoint,
                    baseDocument: baseDocument,
                    episodeID: episode.episodeID,
                    record: record,
                    relativePath: relativePath,
                    runID: runID,
                    modelContext: modelContext,
                    ignoresCancellation: true
                )
            }
        } catch {
            if let checkpoint = pendingCheckpoint {
                do {
                    try await persistCheckpoint(
                        checkpoint,
                        baseDocument: baseDocument,
                        episodeID: episode.episodeID,
                        record: record,
                        relativePath: relativePath,
                        runID: runID,
                        modelContext: modelContext,
                        ignoresCancellation: true
                    )
                } catch {
                    AdFreePassBackgroundRunLog.record(
                        "transcription pending checkpoint flush failed episodeID=\(episode.episodeID) error=\(error.localizedDescription)"
                    )
                }
            }
            throw error
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

    /// A lower compute rung cannot free storage, so this skips the retry ladder.
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

            // The CPU-only retry is a Whisper mechanism; an Apple Speech run restarts from zero.
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

    /// Delete paths cancel the run without awaiting it and leave its stamps, so `ownsActiveRun` alone
    /// misses a record deleted mid-run. `episodeID` comes separately so a deleted record is never read.
    private func isPersistableRunRecord(
        _ record: EpisodeTranscriptRecord,
        episodeID: String,
        modelContext: ModelContext
    ) -> Bool {
        let storedRecord = try? fetchStoredRecord(episodeID: episodeID, modelContext: modelContext)
        return storedRecord === record && storedRecord?.state == .running
    }

    private func placeStagedDocument(
        at stagedURL: URL,
        relativePath: String,
        record: EpisodeTranscriptRecord,
        episodeID: String,
        runID: UUID,
        modelContext: ModelContext
    ) throws {
        guard ownsActiveRun(episodeID: episodeID, runID: runID),
              isPersistableRunRecord(record, episodeID: episodeID, modelContext: modelContext)
        else {
            fileStore.discardStagedDocument(at: stagedURL)
            throw CancellationError()
        }
        try fileStore.placeStagedDocument(at: stagedURL, relativePath: relativePath)
    }

    private func persistCheckpoint(
        _ checkpoint: OpenCastLongFormTranscriptionCheckpoint,
        baseDocument: EpisodeTranscriptDocument?,
        episodeID: String,
        record: EpisodeTranscriptRecord,
        relativePath: String,
        runID: UUID,
        modelContext: ModelContext,
        ignoresCancellation: Bool = false
    ) async throws {
        guard isPersistableRunRecord(record, episodeID: episodeID, modelContext: modelContext) else {
            throw CancellationError()
        }
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
        let stagedURL = try await fileStore.stageOffCaller(
            document,
            relativePath: relativePath,
            ignoringCancellation: ignoresCancellation
        )
        try placeStagedDocument(
            at: stagedURL,
            relativePath: relativePath,
            record: record,
            episodeID: episodeID,
            runID: runID,
            modelContext: modelContext
        )
        if !ignoresCancellation {
            try Task.checkCancellation()
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
        episodeID: String,
        record: EpisodeTranscriptRecord,
        relativePath: String,
        runID: UUID,
        modelContext: ModelContext
    ) async throws {
        guard isPersistableRunRecord(record, episodeID: episodeID, modelContext: modelContext) else {
            throw CancellationError()
        }
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
        let stagedURL = try await fileStore.stageOffCaller(document, relativePath: relativePath)
        try placeStagedDocument(
            at: stagedURL,
            relativePath: relativePath,
            record: record,
            episodeID: episodeID,
            runID: runID,
            modelContext: modelContext
        )
        try Task.checkCancellation()

        record.state = .completed
        record.completedDuration = record.audioDuration
        record.checkpointCount = checkpoints.count
        record.errorMessage = nil
        record.updatedAt = .now
        try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        replacementStopsByEpisodeID[record.episodeID] = nil
        deleteSupersededTranscriptDocuments(
            episodeID: record.episodeID,
            keeping: relativePath,
            prior: takePriorCompletedTranscriptSnapshot(for: record.episodeID)?.transcriptRelativePath
        )
        AdFreePassBackgroundRunLog.record(
            "transcription completed model=\(record.modelIdentifier) version=\(record.modelVersion) audio=\(result.timings.audioDuration.backgroundLogSeconds) transcription=\(result.timings.transcription.backgroundLogSeconds) fullPipeline=\(result.timings.fullPipeline.backgroundLogSeconds) rtf=\(result.timings.realTimeFactor.backgroundLogNumber) segments=\(segments.count) checkpoints=\(checkpoints.count) relativePath=\(relativePath)"
        )
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
    }

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
        let stagedURL = try await fileStore.stageOffCaller(document, relativePath: relativePath)
        let priorRelativePath: String?
        do {
            try Task.checkCancellation()
            // A run admitted during the write owns the record now, and may
            // hold the prior transcript to restore; the commit below would
            // take the record from it and sweep that document away.
            guard activeEngine(for: document.episodeID) == nil else {
                throw RemoteTranscriptImportError.localTranscriptionActive
            }
            let priorRecord = try fetchStoredRecord(
                episodeID: document.episodeID,
                modelContext: modelContext
            )
            priorRelativePath = priorRecord?.state == .completed
                ? priorRecord?.transcriptRelativePath
                : nil
        } catch {
            fileStore.discardStagedDocument(at: stagedURL)
            throw error
        }
        try fileStore.placeStagedDocument(at: stagedURL, relativePath: relativePath)

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
        replacementStopsByEpisodeID[document.episodeID] = nil
        deleteSupersededTranscriptDocuments(
            episodeID: document.episodeID,
            keeping: relativePath,
            prior: priorRelativePath
        )
        notifyEpisodeStateChanged(document.episodeID)
    }

    private func deleteSupersededTranscriptDocuments(
        episodeID: String,
        keeping relativePath: String,
        prior priorRelativePath: String?
    ) {
        do {
            try fileStore.deleteTranscripts(forEpisodeID: episodeID, keeping: relativePath)
            if let priorRelativePath, priorRelativePath != relativePath {
                try fileStore.delete(relativePath: priorRelativePath)
            }
        } catch {
            AdFreePassBackgroundRunLog.record(
                "transcription superseded documents cleanup failed episodeID=\(episodeID) error=\(error.localizedDescription)"
            )
        }
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
            let stopsReplacement = activePriorCompletedTranscriptPolicy == .preserveKeepingInterruptedPartial
                && priorCompletedTranscriptSnapshot?.episodeID == episodeID
            let interruptsReplacement = activeCancellationPreservesPartial && stopsReplacement
            guard record.state != .completed else {
                // Stopped during setup: the record is still the prior
                // transcript, but the replacement is no less unfinished.
                if stopsReplacement {
                    noteStoppedReplacement(episodeID: episodeID)
                }
                return
            }

            if let snapshot = takePriorCompletedTranscriptSnapshot(for: episodeID) {
                try restore(
                    snapshot,
                    onto: record,
                    discardingPartialAt: interruptsReplacement && engine == .whisper
                        ? nil
                        : relativePath ?? record.transcriptRelativePath,
                    modelContext: modelContext
                )
                if stopsReplacement {
                    noteStoppedReplacement(episodeID: episodeID)
                }
                if activeCancellationPreservesPartial, engine == .appleSpeech {
                    onAppleSpeechRunInterrupted?(episodeID, true)
                }
                return
            }

            if activeCancellationPreservesPartial {
                record.state = .interrupted
                record.errorMessage = activeInterruptionHoldsForAutoResume ? Self.environmentalInterruptMessage : nil
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
                // The prior transcript comes back while the failure stays surfaced.
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
                let keepsReplacement = activePriorCompletedTranscriptPolicy == .preserveKeepingInterruptedPartial
                try restore(
                    snapshot,
                    onto: record,
                    discardingPartialAt: keepsReplacement && engine == .whisper
                        ? nil
                        : relativePath ?? record.transcriptRelativePath,
                    modelContext: modelContext
                )
                if keepsReplacement {
                    noteInterruptedReplacement(episodeID: record.episodeID, isEnvironmental: true)
                }
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

    private func noteInterruptedReplacement(episodeID: String, isEnvironmental: Bool) {
        replacementStopsByEpisodeID[episodeID] = .interrupted(
            EpisodeTranscriptionReplacementInterruption(isEnvironmental: isEnvironmental)
        )
        AdFreePassBackgroundRunLog.record(
            "transcription replacement interrupted episodeID=\(episodeID) environmental=\(isEnvironmental)"
        )
    }

    private func noteStoppedReplacement(episodeID: String) {
        guard !activeCancellationPreservesPartial else {
            noteInterruptedReplacement(episodeID: episodeID, isEnvironmental: activeInterruptionHoldsForAutoResume)
            return
        }
        replacementStopsByEpisodeID[episodeID] = .cancelled
        AdFreePassBackgroundRunLog.record(
            "transcription replacement cancelled episodeID=\(episodeID)"
        )
    }

    private func clearActiveRun(episodeID: String, runID: UUID) {
        guard isActiveRun(episodeID: episodeID, runID: runID) else {
            return
        }

        setIdleTimerDisabled(false)
        activeTask = nil
        activeEpisodeID = nil
        activeRunID = nil
        activeSourceFileURL = nil
        activeEngine = nil
        activeCancellationPreservesPartial = false
        activeInterruptionHoldsForAutoResume = false
        activePriorCompletedTranscriptPolicy = .discard
        activeRunEndedByRestore = false
        priorCompletedTranscriptSnapshot = nil
        clearTransientProgress(episodeID: episodeID)
        stateChanges.notify()
    }

    /// A nil `relativePath` keeps the partial for an interrupted Whisper replacement to resume from.
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
        var fetchedRecords = try fetchRecords(modelContext: modelContext)
        var changed = false

        let repairedGroupCount = repairDuplicateRecordGroups(&fetchedRecords, modelContext: modelContext)
        if repairedGroupCount > 0 {
            duplicateRepairCount += repairedGroupCount
            changed = true
        }

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

    private func repairDuplicateRecordGroups(
        _ fetchedRecords: inout [EpisodeTranscriptRecord],
        modelContext: ModelContext
    ) -> Int {
        var groupsByEpisodeID: [String: [EpisodeTranscriptRecord]] = [:]
        for record in fetchedRecords {
            groupsByEpisodeID[record.episodeID, default: []].append(record)
        }
        let duplicateGroups = groupsByEpisodeID.values.filter { $0.count > 1 }
        guard !duplicateGroups.isEmpty else {
            return 0
        }

        let subscribedFeedURLs = EpisodeSidecarRepair.subscribedFeedURLs(modelContext: modelContext)
        var removedIdentities = Set<ObjectIdentifier>()
        for group in duplicateGroups {
            for deleted in collapseDuplicateRecords(
                group,
                subscribedFeedURLs: subscribedFeedURLs,
                modelContext: modelContext
            ) {
                removedIdentities.insert(ObjectIdentifier(deleted))
            }
        }
        fetchedRecords.removeAll { removedIdentities.contains(ObjectIdentifier($0)) }
        return duplicateGroups.count
    }

    /// A survivor that contradicts the proven download is kept but failed, so stale timings are
    /// never presented. Losers' documents go at once: the choice is deterministic, so an interrupted
    /// save re-runs the same collapse.
    private func collapseDuplicateRecords(
        _ group: [EpisodeTranscriptRecord],
        subscribedFeedURLs: Set<String>,
        modelContext: ModelContext
    ) -> [EpisodeTranscriptRecord] {
        guard group.count > 1, let episodeID = group.first?.episodeID else {
            return []
        }

        let downloadHash = provenDownloadHash(episodeID: episodeID, modelContext: modelContext)
        let ordered = group
            .map { record in
                (record: record, score: repairScore(record, downloadHash: downloadHash))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.record.updatedAt != rhs.record.updatedAt {
                    return lhs.record.updatedAt > rhs.record.updatedAt
                }
                if lhs.record.createdAt != rhs.record.createdAt {
                    return lhs.record.createdAt > rhs.record.createdAt
                }
                return EpisodeSidecarRepair.stableOrderingKey(lhs.record)
                    < EpisodeSidecarRepair.stableOrderingKey(rhs.record)
            }
        guard let winner = ordered.first else {
            return []
        }

        if winner.score == 2 {
            winner.record.state = .failed
            winner.record.errorMessage = "Transcript no longer matches the downloaded audio."
            winner.record.updatedAt = .now
        }
        if let podcastID = EpisodeSidecarRepair.preferredPodcastID(
            orderedCandidates: ordered.map(\.record.podcastID),
            subscribedFeedURLs: subscribedFeedURLs
        ), winner.record.podcastID != podcastID {
            winner.record.podcastID = podcastID
            winner.record.updatedAt = .now
        }

        var deletedRecords: [EpisodeTranscriptRecord] = []
        let winnerPath = winner.record.transcriptRelativePath
        for loser in ordered.dropFirst() {
            if let loserPath = loser.record.transcriptRelativePath, loserPath != winnerPath {
                try? fileStore.delete(relativePath: loserPath)
            }
            modelContext.delete(loser.record)
            deletedRecords.append(loser.record)
        }
        return deletedRecords
    }

    private func repairScore(_ record: EpisodeTranscriptRecord, downloadHash: String?) -> Int {
        guard record.state == .completed,
              let relativePath = record.transcriptRelativePath,
              (try? fileStore.read(relativePath: relativePath)) != nil
        else {
            return record.state == .interrupted && hasWhisperResumeMetadata(record) ? 1 : 0
        }
        if let downloadHash, !record.sourceFileSHA256.isEmpty {
            return record.sourceFileSHA256 == downloadHash ? 4 : 2
        }
        return 3
    }

    private func provenDownloadHash(episodeID: String, modelContext: ModelContext) -> String? {
        let targetEpisodeID = episodeID
        let downloadRecords = (try? modelContext.fetch(
            FetchDescriptor<EpisodeDownloadRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                }
            )
        )) ?? []
        let completedHashes = Set(
            downloadRecords
                .filter { $0.state == .completed && !$0.sourceFileSHA256.isEmpty }
                .map(\.sourceFileSHA256)
        )
        return completedHashes.count == 1 ? completedHashes.first : nil
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
        // Apple Speech restarts from zero; resume is a Whisper checkpoint mechanism.
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
        guard document.checkpoints.count == record.checkpointCount,
              let checkpoint = WhisperResumeExpectation(record: record).lastResumableCheckpoint(of: document),
              checkpoint.completedDuration <= record.completedDuration
        else {
            return nil
        }
        return (checkpoint.completedDuration, document)
    }

    /// The record holds the restored prior transcript, so only the partial at this run's path can
    /// say where to resume, checked against what this run will write.
    private func resumableInterruptedReplacementState(
        at relativePath: String,
        expecting expectation: WhisperResumeExpectation,
        engine: EpisodeTranscriptionEngine
    ) async -> (start: TimeInterval, document: EpisodeTranscriptDocument)? {
        guard engine == .whisper,
              OpenCastWhisperModel.allCases.contains(where: {
                  $0.rawValue == expectation.modelIdentifier
              }),
              let document = try? await fileStore.readOffCaller(relativePath: relativePath),
              let checkpoint = expectation.lastResumableCheckpoint(of: document)
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
        scheduleEpisodeSearchIndexUpdate(for: record)
        notifyEpisodeStateChanged(record.episodeID)
    }

    private func reload(modelContext: ModelContext) throws {
        records = try fetchRecords(modelContext: modelContext)
        hasAuthoritativeRecords = true
        scheduleEpisodeSearchIndexReconciliation()
    }

    func waitForEpisodeSearchIndexSync() async {
        await episodeSearchIndexSyncTask?.value
    }

    private func scheduleEpisodeSearchIndexUpdate(
        for record: EpisodeTranscriptRecord
    ) {
        guard let store = episodeSearchIndexStore else {
            return
        }
        let episodeID = record.episodeID
        let snapshot = searchIndexSnapshot(for: record)
        if snapshot == nil {
            // Otherwise every progress checkpoint would enqueue a remove for an episode the index has
            // never seen.
            guard searchIndexCandidateEpisodeIDs.contains(episodeID) else {
                return
            }
            searchIndexCandidateEpisodeIDs.remove(episodeID)
        } else {
            searchIndexCandidateEpisodeIDs.insert(episodeID)
        }
        let fileStore = fileStore
        enqueueEpisodeSearchIndexOperation {
            do {
                if let snapshot,
                   let document = try? await fileStore.readOffCaller(
                    relativePath: snapshot.relativePath
                   ),
                   document.episodeID == snapshot.episodeID {
                    let searchDocument = EpisodeSearchTranscriptDocument(
                        document
                    )
                    try await Self.retryingAfterIndexPreparation(store) {
                        try await store.replaceEpisodeTranscriptSearchDocument(
                            searchDocument
                        )
                    }
                } else {
                    try await Self.retryingAfterIndexPreparation(store) {
                        try await store.removeEpisodeTranscriptSearchDocument(
                            episodeID: episodeID
                        )
                    }
                }
            } catch is CancellationError {
            } catch {
                // A derived index: the next load reconciles it.
            }
        }
    }

    private static func retryingAfterIndexPreparation(
        _ store: any LocalLibraryCacheStore,
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch is EpisodeSearchIndexError {
            try await store.prepareEpisodeSearchIndex()
            try await operation()
        }
    }

    private func registerEpisodeSearchIndexRebuildHandler() {
        guard let store = episodeSearchIndexStore else {
            return
        }
        Task { [weak self] in
            // A rebuild restores metadata from `episode_cache` but cannot read transcript sidecars.
            await store.setEpisodeSearchIndexRebuildHandler {
                self?.scheduleEpisodeSearchIndexReconciliation()
            }
        }
    }

    private func scheduleEpisodeSearchIndexReconciliation() {
        guard let store = episodeSearchIndexStore, hasAuthoritativeRecords else {
            return
        }
        var snapshotsByEpisodeID: [String: EpisodeSearchIndexDocumentSnapshot] = [:]
        for record in records {
            if let snapshot = searchIndexSnapshot(for: record),
               snapshotsByEpisodeID[snapshot.episodeID] == nil {
                snapshotsByEpisodeID[snapshot.episodeID] = snapshot
            }
        }
        if let priorCompletedTranscriptSnapshot,
           let relativePath =
            priorCompletedTranscriptSnapshot.transcriptRelativePath,
           snapshotsByEpisodeID[priorCompletedTranscriptSnapshot.episodeID] == nil {
            snapshotsByEpisodeID[priorCompletedTranscriptSnapshot.episodeID] =
                EpisodeSearchIndexDocumentSnapshot(
                    episodeID: priorCompletedTranscriptSnapshot.episodeID,
                    relativePath: relativePath
                )
        }
        let snapshots = snapshotsByEpisodeID.values.sorted {
            $0.episodeID < $1.episodeID
        }
        searchIndexCandidateEpisodeIDs = Set(snapshotsByEpisodeID.keys)
        let fileStore = fileStore
        enqueueEpisodeSearchIndexOperation {
            do {
                try await store.prepareEpisodeSearchIndex()
                var retainedEpisodeIDs: Set<String> = []
                for snapshot in snapshots {
                    try Task.checkCancellation()
                    guard let document = try? await fileStore.readOffCaller(
                        relativePath: snapshot.relativePath
                    ), document.episodeID == snapshot.episodeID else {
                        continue
                    }
                    try await store.replaceEpisodeTranscriptSearchDocument(
                        EpisodeSearchTranscriptDocument(document)
                    )
                    retainedEpisodeIDs.insert(snapshot.episodeID)
                }
                try Task.checkCancellation()
                try await store.reconcileEpisodeTranscriptSearchDocuments(
                    retaining: retainedEpisodeIDs
                )
            } catch is CancellationError {
            } catch {
                // Search is derived and self-healing; never fail transcript
                // loading, completion, or deletion because indexing failed.
            }
        }
    }

    private func searchIndexSnapshot(
        for record: EpisodeTranscriptRecord
    ) -> EpisodeSearchIndexDocumentSnapshot? {
        if record.state == .completed,
           let relativePath = record.transcriptRelativePath {
            return EpisodeSearchIndexDocumentSnapshot(
                episodeID: record.episodeID,
                relativePath: relativePath
            )
        }
        if let priorCompletedTranscriptSnapshot,
           let relativePath =
            priorCompletedTranscriptSnapshot.transcriptRelativePath,
           priorCompletedTranscriptSnapshot.episodeID == record.episodeID {
            return EpisodeSearchIndexDocumentSnapshot(
                episodeID: record.episodeID,
                relativePath: relativePath
            )
        }
        return nil
    }

    private func enqueueEpisodeSearchIndexOperation(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let precedingTask = episodeSearchIndexSyncTask
        episodeSearchIndexSyncTask = Task {
            await precedingTask?.value
            guard !Task.isCancelled else {
                return
            }
            await operation()
        }
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

    /// A rewrite is the whole cumulative document: about 20 MB of writes for a one-hour episode when
    /// every checkpoint writes.
    static let checkpointDocumentWriteInterval = 5

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
        isActiveRun(episodeID: episodeID, runID: runID) && !activeRunEndedByRestore
    }

    private func isActiveRun(episodeID: String, runID: UUID) -> Bool {
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

}

private struct EpisodeSearchIndexDocumentSnapshot: Sendable {
    let episodeID: String
    let relativePath: String
}

private struct WhisperResumeExpectation {
    let episodeID: String
    let podcastID: String
    let sourceAudioURL: String
    let sourceFileByteCount: Int64
    let sourceFileSHA256: String
    let modelIdentifier: String
    let modelVersion: String
    let modelTreeSHA256: String
    let languageCode: String
    let audioDuration: TimeInterval

    init(record: EpisodeTranscriptRecord) {
        episodeID = record.episodeID
        podcastID = record.podcastID
        sourceAudioURL = record.sourceAudioURL
        sourceFileByteCount = record.sourceFileByteCount
        sourceFileSHA256 = record.sourceFileSHA256
        modelIdentifier = record.modelIdentifier
        modelVersion = record.modelVersion
        modelTreeSHA256 = record.modelTreeSHA256
        languageCode = record.languageCode
        audioDuration = record.audioDuration
    }

    init(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: String,
        sourceFileByteCount: Int64,
        sourceFileSHA256: String,
        modelIdentity: EpisodeTranscriptionModelIdentity,
        languageCode: String,
        audioDuration: TimeInterval
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.sourceAudioURL = sourceAudioURL
        self.sourceFileByteCount = sourceFileByteCount
        self.sourceFileSHA256 = sourceFileSHA256
        modelIdentifier = modelIdentity.modelIdentifier
        modelVersion = modelIdentity.version
        modelTreeSHA256 = modelIdentity.treeSHA256
        self.languageCode = languageCode
        self.audioDuration = audioDuration
    }

    func lastResumableCheckpoint(of document: EpisodeTranscriptDocument) -> EpisodeTranscriptCheckpoint? {
        guard document.schemaVersion > 0,
              document.schemaVersion <= EpisodeTranscriptDocument.currentSchemaVersion,
              document.episodeID == episodeID,
              document.podcastID == podcastID,
              document.sourceAudioURL == sourceAudioURL,
              document.sourceFileByteCount == sourceFileByteCount,
              document.sourceFileSHA256 == sourceFileSHA256,
              document.modelIdentifier == modelIdentifier,
              document.modelVersion == modelVersion,
              document.modelTreeSHA256 == modelTreeSHA256,
              document.languageCode == languageCode,
              document.audioDuration == audioDuration,
              let checkpoint = document.checkpoints.last,
              checkpoint.completedDuration.isFinite,
              checkpoint.completedDuration > 0,
              checkpoint.completedDuration < audioDuration,
              checkpoint.segmentCount == document.segments.count,
              document.checkpoints.allSatisfy({
                  $0.completedDuration <= checkpoint.completedDuration
              })
        else {
            return nil
        }
        return checkpoint
    }
}

/// In memory only: after a force-quit the record relaunches interrupted on the partial
/// replacement.
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
