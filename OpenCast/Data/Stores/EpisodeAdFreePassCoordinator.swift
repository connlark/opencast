import Foundation
import Observation
import OpenCastTranscription
import SwiftData

@Observable
final class EpisodeAdFreePassCoordinator {
    private enum FailureMessage {
        static let transcriptFailed = "Transcript failed."
        static let transcriptCancelled = "Transcript cancelled."
        static let transcriptUnavailable = "Transcript unavailable."
        static let analysisFailed = "Promo/ad analysis failed."
    }

    private(set) var queueState: AdFreePassQueueState = .idle
    private(set) var activeItem: AdFreePassQueueItem?
    private(set) var currentStage: EpisodeAdFreePassStage?
    private(set) var drainCompletedCount = 0
    private(set) var drainFailedCount = 0
    private(set) var drainOutcomes: [AdFreePassQueueItemOutcome] = []
    private(set) var pendingModelConsentEpisodeID: String?
    private(set) var pendingModelConsentByteCount: Int64?
    private(set) var lastFailureEpisodeID: String?
    private(set) var lastFailureMessage: String?
    private var failureMessagesByEpisodeID: [String: String] = [:]
    private var uiProgressMapper = AdFreePassQueueProgressMapper()

    @ObservationIgnored let cancellationSource: AdFreePassCancellationSource
    @ObservationIgnored private var passTask: Task<Void, Never>?
    /// Ownership token for the running drain: bumped by startDrain and
    /// reset() so a cancelled drain resuming after an await cannot mutate a
    /// successor drain's queue state.
    @ObservationIgnored private var drainGeneration = 0
    // Observed (not ignored) so pending-queue mutations — enqueue, drain,
    // removePendingItem — invalidate views reading queueStatus/queueSnapshot.
    private var entries: [QueueEntry] = []
    @ObservationIgnored private var lastPublishedStage: EpisodeAdFreePassStage?
    @ObservationIgnored private var activeTranscriptionEngine: AdFreePassTranscriptionEngine = .productDefault
    @ObservationIgnored private var activeTranscriptionModelIdentity: EpisodeTranscriptionModelIdentity?
    @ObservationIgnored private var stickyComputeProfile: OpenCastTranscriptionComputeProfile?
    @ObservationIgnored private var pausedForEnvironmentalInterrupt = false
    /// The environmental pause holds an unattended item for the lifecycle
    /// (nobody there to run it), not for a compute failure; only this kind
    /// resumes once the work may run again without the app coming back.
    @ObservationIgnored private var pausedForLifecycleHold = false
    /// The active item whose pass stops into a lifecycle hold, however its
    /// transcription then ends.
    @ObservationIgnored private var lifecycleHoldEpisodeID: String?
    /// The transcription this queue started for its active item, as opposed
    /// to one it joined.
    @ObservationIgnored private var ownedTranscription: OwnedTranscription?
    @ObservationIgnored private var lastInterruptedEpisodeID: String?
    /// The running cloud item's job store, so a user cancel can persist its
    /// intent before the local task is cancelled.
    @ObservationIgnored private var activeCloudJobStore: RemoteTranscriptionJobStore?
    /// The running item's analysis store, so a cancel stops its device run.
    @ObservationIgnored private var activeAdAnalyses: EpisodeAdAnalysisStore?
    /// User cancels of cloud items in flight, keyed by episode. Each deletes
    /// its queue record only after the runner recorded the cancel attempt,
    /// and a new start for the same episode waits for it.
    @ObservationIgnored private var cloudUserCancels: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let launchPreparationGate: @Sendable () async -> Void
    @ObservationIgnored var onStageChange: (@MainActor (EpisodeAdFreePassStage, AdFreePassQueueContext) -> Void)?
    @ObservationIgnored var onQueueTerminal: (@MainActor (AdFreePassQueueTerminalOutcome) -> Void)?
    /// Shows the key screen for ad detection; called for each item the
    /// listener started that ended needing a key, never for automatic ones.
    @ObservationIgnored var onKeyRequired: (@MainActor (AnalysisKeyRequiredReason) -> Void)?
    @ObservationIgnored var isBackgroundProtected: @MainActor () -> Bool = { false }
    @ObservationIgnored var requiresNonGPUCompute: @MainActor () -> Bool = { false }
    /// Whether an item nobody tapped may run now; asked before such an item
    /// starts its own transcription, and when its lifecycle hold lands.
    @ObservationIgnored var allowsUnattendedWork: @MainActor () -> Bool = { true }

    var initialWhisperComputeProfile: OpenCastTranscriptionComputeProfile {
        stickyComputeProfile ?? (requiresNonGPUCompute() ? .cpuAndNeuralEngine : .backgroundSafe)
    }
    /// UI-testing stand-in for the live queue (App Store pipeline shot): the
    /// snapshot and per-episode status come from the override, nothing runs.
    @ObservationIgnored var uiTestQueueOverride: AdFreePassQueueUITestOverride?
    @ObservationIgnored var uiTestEpisodeSnapshotResolver: (@MainActor (String) -> EpisodeListItemSnapshot?)?

    init(
        cancellationSource: AdFreePassCancellationSource = AdFreePassCancellationSource(),
        launchPreparationGate: @escaping @Sendable () async -> Void = {}
    ) {
        self.cancellationSource = cancellationSource
        self.launchPreparationGate = launchPreparationGate
    }

    var activeEpisodeID: String? {
        activeItem?.episodeID
    }

    var queueItems: [AdFreePassQueueItem] {
        entries.map(\.item)
    }

    var isQueuePausedForEnvironmentalInterrupt: Bool {
        queueState == .pausedInterrupted && pausedForEnvironmentalInterrupt
    }

    /// Paused with an item nobody tapped held at the head, to resume by
    /// itself.
    var isHoldingUnattendedItem: Bool {
        isQueuePausedForEnvironmentalInterrupt && entries.first?.item.origin.isUnattended == true
    }

    /// Whether the store's active transcription is one this queue started
    /// for its active unattended item.
    var ownsUnattendedActiveTranscription: Bool {
        activeItem?.origin.isUnattended == true && ownsActiveTranscription
    }

    private var ownsActiveTranscription: Bool {
        guard let ownedTranscription else {
            return false
        }
        return ownedTranscription.transcriptions.activeRunID == ownedTranscription.runID
    }

    var queueSnapshot: AdFreePassQueueSnapshot {
        if let uiTestQueueOverride {
            return overriddenQueueSnapshot(uiTestQueueOverride)
        }

        return AdFreePassQueueSnapshot(
            state: queueState,
            activeEpisodeID: activeItem?.episodeID,
            activeEpisodeTitle: activeItem?.episode.title,
            activeArtworkURL: activeItem?.episode.artworkURL,
            activeItemMode: activeItem?.mode,
            currentStage: activeItem != nil ? currentStage : nil,
            finishedItemCount: finishedItemCount,
            totalItemCount: drainTotalItemCount,
            completedCount: drainCompletedCount,
            failedCount: drainFailedCount,
            fractionCompleted: uiProgressMapper.fractionCompleted,
            outcomes: drainOutcomes,
            pendingItems: entries.map(\.item),
            pendingModelConsentByteCount: pendingModelConsentByteCount
        )
    }

    func queueStatus(for episodeID: String) -> AdFreePassQueueEpisodeStatus {
        if let uiTestQueueOverride {
            if uiTestQueueOverride.activeEpisodeID == episodeID {
                return .running
            }
            if let index = uiTestQueueOverride.pendingEpisodeIDs.firstIndex(of: episodeID) {
                return .queued(ahead: index + 1)
            }
            return .notQueued
        }

        if activeItem?.episodeID == episodeID {
            return .running
        }

        if let index = entries.firstIndex(where: { $0.item.episodeID == episodeID }) {
            if let reason = entries[index].item.remoteParkReason {
                return .remoteParked(reason)
            }
            let ahead = index + (activeItem != nil ? 1 : 0)
            return .queued(ahead: ahead)
        }

        if let outcome = drainOutcomes.last(where: { $0.episodeID == episodeID }) {
            switch outcome.kind {
            case .completed(let zoneCount):
                return .completed(zoneCount: zoneCount)
            case .failed(let message):
                return .failed(message: message)
            case .cloudUnavailable(let message):
                return .cloudUnavailable(message: message)
            case .keyRequired(let reason):
                return .keyRequired(reason)
            }
        }

        return .notQueued
    }

    private func overriddenQueueSnapshot(_ override: AdFreePassQueueUITestOverride) -> AdFreePassQueueSnapshot {
        let activeEpisode = uiTestEpisodeSnapshotResolver?(override.activeEpisodeID)
        let pendingItems = override.pendingEpisodeIDs.enumerated().compactMap { index, episodeID in
            uiTestEpisodeSnapshotResolver?(episodeID).map { episode in
                AdFreePassQueueItem(episode: episode, origin: .manual, enqueuedAt: .now, sequence: index + 1)
            }
        }
        let itemCount = 1 + pendingItems.count
        let activeFraction: Double = switch override.stage {
        case .downloadingEpisode:
            0.1
        case .transcribing(let progress):
            0.2 + 0.6 * (progress.fractionCompleted ?? 0)
        case .analyzing:
            0.9
        default:
            0.5
        }

        return AdFreePassQueueSnapshot(
            state: .running,
            activeEpisodeID: override.activeEpisodeID,
            activeEpisodeTitle: activeEpisode?.title,
            activeArtworkURL: activeEpisode?.artworkURL,
            activeItemMode: .onDevice,
            currentStage: override.stage,
            finishedItemCount: 0,
            totalItemCount: itemCount,
            completedCount: 0,
            failedCount: 0,
            fractionCompleted: activeFraction / Double(itemCount),
            outcomes: [],
            pendingItems: pendingItems,
            pendingModelConsentByteCount: nil
        )
    }

    func presentation(
        for episode: EpisodeListItemSnapshot?,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        appleSpeechAssets: AppleSpeechAssetStore,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        currentZoneCount: Int
    ) -> EpisodeAdFreePassPresentation {
        guard let episode else {
            return .unavailable("No episode playing.")
        }

        let episodeID = episode.episodeID

        if pendingModelConsentEpisodeID == episodeID,
           let pendingModelConsentByteCount {
            return .awaitingModelConsent(byteCount: pendingModelConsentByteCount)
        }

        if let queuedPresentation = queuedPresentation(for: episodeID) {
            return queuedPresentation
        }

        // A hold can land before the transcription wrote a record, which
        // would read as never started.
        if pausedForLifecycleHold, isHoldingUnattendedItem, entries.first?.item.episodeID == episodeID {
            return .pausedInBackground
        }

        // Cloud stages live entirely in the coordinator (no local store
        // reflects them), so the active cloud item presents from its stage.
        if activeEpisodeID == episodeID, let currentStage {
            switch currentStage {
            case .cloudQueued:
                return .cloudQueued
            case .cloudVerifying:
                return .cloudVerifying
            case .cloudUploadingExactCopy(let completedParts, let totalParts):
                return .cloudUploadingExactCopy(completedParts: completedParts, totalParts: totalParts)
            case .cloudWaitingForCredits:
                return .cloudWaitingForCredits
            case .cloudTranscribing(let progress):
                return .cloudTranscribing(progress)
            case .cloudFinishing:
                return .cloudFinishing
            case .cloudUnavailable(let message):
                return .cloudUnavailable(message)
            case .cloudParked(let reason):
                return .remoteParked(reason)
            default:
                break
            }
        }

        if activeEpisodeID == nil,
           let outcome = drainOutcomes.last(where: { $0.episodeID == episodeID }),
           case .cloudUnavailable(let message) = outcome.kind {
            return .cloudUnavailable(message)
        }

        if activeEpisodeID == nil,
           let lastFailure = failureMessage(for: episodeID) {
            return .failed(lastFailure)
        }

        if let record = downloads.record(for: episodeID) {
            switch record.state {
            case .downloading:
                return .downloadingEpisode
            case .paused:
                return .failed("Download paused.")
            case .failed, .missing:
                return .failed(record.errorMessage ?? EpisodeDownloadError.missingDownloadedFile.localizedDescription)
            case .completed:
                break
            }
        }

        let presentationEngine = activeEpisodeID == episodeID
            ? activeTranscriptionEngine
            : .productDefault
        let requiresWhisperModel = presentationRequiresWhisperModel(
            for: presentationEngine,
            appleSpeechAssets: appleSpeechAssets
        )

        if activeEpisodeID == episodeID,
           case .installing(_, let fractionCompleted) = appleSpeechAssets.state {
            return .installingSpeechAssets(fractionCompleted: fractionCompleted)
        }

        if requiresWhisperModel {
            switch transcriptionModels.state {
            case .checking:
                return .checkingModel
            case .installing(let progress):
                return .installingModel(progress)
            case .deleting:
                return .modelBusy
            case .failed(let message) where activeEpisodeID == episodeID:
                return .failed(message)
            case .unknown, .notInstalled, .installed, .repairAvailable, .failed:
                break
            }
        }

        let downloadRecord = downloads.record(for: episodeID)
        let transcriptRecord: EpisodeTranscriptRecord
        switch transcriptions.jobState(
            for: episodeID,
            downloadRecord: downloadRecord,
            modelState: transcriptionModels.state,
            modelIdentity: activeEpisodeID == episodeID ? activeTranscriptionModelIdentity : nil,
            requiresInstalledWhisperModel: requiresWhisperModel
        ) {
        case .running(let progress):
            return .transcribing(progress)
        case .failed(let record):
            return .failed(record.errorMessage ?? "Transcript failed.")
        case .cancelled:
            return .failed("Transcript cancelled.")
        case .interrupted(let record):
            return transcriptions.isEnvironmentalInterruption(record) ? .pausedInBackground : .interrupted
        case .completed(let record):
            transcriptRecord = record
        case .unavailable, .downloadRequired, .modelRequired, .modelBusy, .ready:
            if let lastFailure = failureMessage(for: episodeID) {
                return .failed(lastFailure)
            }
            return .idle
        }

        if adAnalyses.isRunning(for: episodeID) {
            return .analyzing
        }

        guard let analysisRecord = adAnalyses.record(for: episodeID) else {
            if let lastFailure = failureMessage(for: episodeID) {
                return .failed(lastFailure)
            }
            if let unavailableMessage = adAnalyses.analysisStartUnavailableMessage {
                return .unavailable(unavailableMessage)
            }
            return .idle
        }

        switch analysisRecord.state {
        case .queued, .running:
            return .analyzing
        case .completed:
            guard let isCurrent = completedAnalysisVerdictIfAvailable(
                for: episodeID,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses
            ) else {
                return .checkingAnalysis
            }
            guard isCurrent else {
                return .outdated
            }
            return isAnalysisAttached(for: episodeID, transcriptions: transcriptions, downloads: downloads)
                ? .completed(zoneCount: currentZoneCount)
                : .detached
        case .failed:
            guard analysisRecord.transcriptState == .completed,
                  analysisRecord.transcriptUpdatedAt.truncatedToWholeSeconds
                    == transcriptRecord.updatedAt.truncatedToWholeSeconds
            else {
                return .outdated
            }
            return .failed(analysisRecord.errorMessage ?? "Promo/ad analysis failed.")
        }
    }

    func enqueue(
        episode: EpisodeListItemSnapshot,
        origin: AdFreePassQueueOrigin,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        appleSpeechAssets: AppleSpeechAssetStore,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        modelContext: ModelContext,
        transcriptionEngine: AdFreePassTranscriptionEngine = .productDefault,
        podcastLanguageCode: String? = nil,
        mode: AdDetectionMode = .onDevice,
        remoteRunner: RemoteTranscriptionJobRunner? = nil,
        remoteJobStore: RemoteTranscriptionJobStore? = nil,
        remotePurchases: RemoteTranscriptionPurchaseStore? = nil,
        presentsKeyScreen: Bool = true,
        prepareBackgroundSession: @escaping @MainActor () -> Void = {},
        refreshSkipZones: @escaping @MainActor () async -> Int
    ) {
        let episodeID = episode.episodeID
        // Only a manual start is the listener's; `presentsKeyScreen` is false
        // when the app restarts one for them (an environmental resume).
        let isListenerStart = origin == .manual && presentsKeyScreen

        guard activeItem?.episodeID != episodeID else {
            return
        }

        if let index = entries.firstIndex(where: { $0.item.episodeID == episodeID }) {
            if isListenerStart {
                entries[index].presentsKeyScreen = true
            }
            resumePausedQueueIfHeadReEnqueued(
                episodeID: episodeID,
                prepareBackgroundSession: prepareBackgroundSession
            )
            return
        }

        beginDrainSessionIfNeeded()

        let insertsAtFront = origin == .auto
            || (queueState == .pausedInterrupted && lastInterruptedEpisodeID == episodeID)
        let item = AdFreePassQueueItem(
            episode: episode,
            origin: origin,
            enqueuedAt: .now,
            sequence: nextSequence(front: insertsAtFront),
            mode: Self.mode(mode, for: origin)
        )
        let dependencies = PassDependencies(
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            modelContext: modelContext,
            transcriptionEngine: transcriptionEngine,
            podcastLanguageCode: podcastLanguageCode,
            prepareBackgroundSession: prepareBackgroundSession,
            refreshSkipZones: refreshSkipZones,
            remoteRunner: remoteRunner,
            remoteJobStore: remoteJobStore,
            remotePurchases: remotePurchases
        )
        let launchPreparation = Task { [weak self] in
            await Task.yield()
            guard let self else {
                return LaunchPreparationOutcome.failed
            }
            return await self.prepareAcceptedItemLaunch(
                item: item,
                dependencies: dependencies
            )
        }
        let entry = QueueEntry(
            item: item,
            deps: dependencies,
            launchPreparation: launchPreparation,
            presentsKeyScreen: isListenerStart
        )
        if insertsAtFront {
            entries.insert(entry, at: 0)
        } else {
            entries.append(entry)
        }
        clearFailure(episodeID: episodeID)

        switch queueState {
        case .idle:
            startDrain()
        case .pausedInterrupted where lastInterruptedEpisodeID == episodeID:
            startDrain()
        case .running, .pausedInterrupted, .awaitingModelConsent:
            break
        }
        SoundLabResponsivenessDiagnostics.mark(
            "queue-state-acknowledged",
            episodeID: episodeID
        )
    }

    func restorePersistedQueue(
        resolveEpisode: (String) -> EpisodeListItemSnapshot?,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        appleSpeechAssets: AppleSpeechAssetStore,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        modelContext: ModelContext,
        podcastLanguageCode: (String) -> String?,
        remoteRunner: RemoteTranscriptionJobRunner? = nil,
        remoteJobStore: RemoteTranscriptionJobStore? = nil,
        remotePurchases: RemoteTranscriptionPurchaseStore? = nil,
        refreshSkipZones: @escaping @MainActor (EpisodeListItemSnapshot) async -> Int
    ) {
        let records: [AdFreePassQueueItemRecord]
        do {
            records = try modelContext.fetch(
                FetchDescriptor<AdFreePassQueueItemRecord>(sortBy: [SortDescriptor(\.sequence)])
            )
        } catch {
            AdFreePassBackgroundRunLog.record("queue restore fetch failed error=\(error.localizedDescription)")
            return
        }
        guard !records.isEmpty else {
            return
        }

        var didDropRecords = false
        for record in records {
            let alreadyQueued = entries.contains { $0.item.episodeID == record.episodeID }
                || activeItem?.episodeID == record.episodeID
            if alreadyQueued {
                continue
            }

            guard let origin = AdFreePassQueueOrigin(rawValue: record.originRawValue),
                  let episode = resolveEpisode(record.episodeID)
            else {
                modelContext.delete(record)
                didDropRecords = true
                continue
            }

            let mode = Self.mode(AdDetectionMode(rawValue: record.modeRawValue) ?? .onDevice, for: origin)
            if mode == .cloud,
               remoteJobStore?.existingReference(for: record.episodeID, purpose: .adDetection)?
                .userCancelRequestedAt != nil {
                // The user already cancelled this item; the re-attach trigger
                // resolves its persisted intent. Draining it would only run
                // into the runner's refusal.
                modelContext.delete(record)
                didDropRecords = true
                continue
            }
            let item = AdFreePassQueueItem(
                episode: episode,
                origin: origin,
                enqueuedAt: record.enqueuedAt,
                sequence: record.sequence,
                mode: mode,
                remoteParkReason: mode == .cloud
                    ? RemoteTranscriptionJobExit(rawValue: record.remoteParkReasonRawValue)
                    : nil
            )
            // Restored items drain foreground-opportunistically; background
            // continuation always requires a fresh explicit tap.
            // A restored cloud item re-attaches server-side through its
            // stable purpose-keyed clientRequestID.
            let entry = QueueEntry(
                item: item,
                deps: PassDependencies(
                    downloads: downloads,
                    transcriptionModels: transcriptionModels,
                    appleSpeechAssets: appleSpeechAssets,
                    transcriptions: transcriptions,
                    adAnalyses: adAnalyses,
                    modelContext: modelContext,
                    transcriptionEngine: .productDefault,
                    podcastLanguageCode: podcastLanguageCode(episode.podcastID),
                    prepareBackgroundSession: {},
                    refreshSkipZones: { await refreshSkipZones(episode) },
                    remoteRunner: remoteRunner,
                    remoteJobStore: remoteJobStore,
                    remotePurchases: remotePurchases
                ),
                launchPreparation: nil,
                presentsKeyScreen: false
            )
            entries.append(entry)
        }
        if didDropRecords {
            try? modelContext.save()
        }
        AdFreePassBackgroundRunLog.record("queue restored pending=\(entries.count) records=\(records.count)")

        guard !entries.isEmpty, queueState == .idle else {
            return
        }
        beginDrainSessionIfNeeded()
        startDrain()
    }

    /// A new episode's item never creates a cloud job.
    private static func mode(_ mode: AdDetectionMode, for origin: AdFreePassQueueOrigin) -> AdDetectionMode {
        origin == .prepared ? .onDevice : mode
    }

    /// Stops the active item's own transcription so the item waits at the
    /// head, its record kept, and resumes by itself; whatever the stopped
    /// transcription leaves behind, the pass ends held. Only an unattended
    /// item's transcription this queue started is stopped: a manual item, or
    /// a transcription the pass joined, is left alone.
    func holdActiveItemForLifecycle(modelContext: ModelContext) {
        guard let activeItem,
              activeItem.origin.isUnattended,
              let ownedTranscription,
              ownsActiveTranscription
        else {
            return
        }

        lifecycleHoldEpisodeID = activeItem.episodeID
        AdFreePassBackgroundRunLog.record("queue lifecycle hold episodeID=\(activeItem.episodeID)")
        ownedTranscription.transcriptions.interruptActiveJob(modelContext: modelContext, holdsForAutoResume: true)
    }

    /// Resumes a lifecycle hold once its unattended item may run again. A
    /// hold after a compute failure waits for the app, so a failing
    /// background compute cannot loop.
    func resumeLifecycleHoldIfAllowed() {
        guard pausedForLifecycleHold, isHoldingUnattendedItem, allowsUnattendedWork() else {
            return
        }

        AdFreePassBackgroundRunLog.record("queue lifecycle hold resumed episodeID=\(entries.first?.item.episodeID ?? "none")")
        resumeQueueForEnvironmentalAutoResume()
    }

    func resumeQueueForEnvironmentalAutoResume() {
        guard isQueuePausedForEnvironmentalInterrupt else {
            return
        }

        pausedForEnvironmentalInterrupt = false
        markHeadPresentsKeyScreen(false)
        if let prepareBackgroundSession = entries.first?.deps.prepareBackgroundSession {
            scheduleResumeLaunchPreparation(
                prepareBackgroundSession: prepareBackgroundSession
            )
        }
        startDrain()
    }

    /// The listener's Resume (the queue's, the card's or the consent
    /// button): the head is theirs from now on, whoever queued it.
    func resumePausedQueue() {
        switch queueState {
        case .pausedInterrupted, .awaitingModelConsent:
            pausedForEnvironmentalInterrupt = false
            markHeadPresentsKeyScreen(true)
            if let prepareBackgroundSession = entries.first?.deps.prepareBackgroundSession {
                scheduleResumeLaunchPreparation(
                    prepareBackgroundSession: prepareBackgroundSession
                )
            }
            startDrain()
        case .idle, .running:
            break
        }
    }

    func handleForegroundReturn() {
        stickyComputeProfile = nil
    }

    func republishCurrentStage() {
        guard let lastPublishedStage else {
            return
        }
        onStageChange?(lastPublishedStage, currentQueueContext)
    }

    func reset() {
        cancellationSource.cancel(reason: .reset)
        passTask?.cancel()
        passTask = nil
        drainGeneration += 1
        cancellationSource.clearTask()
        for entry in entries {
            entry.launchPreparation?.cancel()
        }
        entries = []
        activeItem = nil
        activeCloudJobStore = nil
        activeAdAnalyses = nil
        currentStage = nil
        queueState = .idle
        drainCompletedCount = 0
        drainFailedCount = 0
        drainOutcomes = []
        uiProgressMapper.reset()
        pendingModelConsentEpisodeID = nil
        pendingModelConsentByteCount = nil
        lastFailureEpisodeID = nil
        lastFailureMessage = nil
        failureMessagesByEpisodeID = [:]
        lastPublishedStage = nil
        activeTranscriptionEngine = .productDefault
        activeTranscriptionModelIdentity = nil
        stickyComputeProfile = nil
        pausedForEnvironmentalInterrupt = false
        pausedForLifecycleHold = false
        lifecycleHoldEpisodeID = nil
        ownedTranscription = nil
        lastInterruptedEpisodeID = nil
    }

    func cancelActivePass() {
        if let activeItem, activeItem.mode == .cloud {
            // Durable before the local task stops, so a death in between
            // still resolves as the user's cancel and never re-attaches.
            activeCloudJobStore?.recordUserCancelIntent(episodeID: activeItem.episodeID, purpose: .adDetection)
        }
        cancellationSource.cancel(reason: .userRequest)
        cancelActiveAnalysisRun(reason: .listener)
    }

    /// Stops the active item's device ad-detection run, on-device or a
    /// cloud item's, so its sends stop with the pass: `.listener` ends the
    /// run, `.expiration` keeps it resumable. A run the item is not waiting
    /// on is left alone.
    func cancelActiveAnalysisRun(reason: EpisodeAdAnalysisCancelReason) {
        guard let activeEpisodeID,
              let activeAdAnalyses,
              activeAdAnalyses.isRunning(for: activeEpisodeID)
        else {
            return
        }
        AdFreePassBackgroundRunLog.record("analysis run cancelled episodeID=\(activeEpisodeID) reason=\(reason)")
        activeAdAnalyses.cancelActiveRun(reason: reason)
    }

    /// Removes a pending item. A cloud item whose server job may exist is a
    /// user cancel: the intent is persisted first, the item leaves the queue
    /// at once, and the returned task sends at most one `/cancel` before it
    /// deletes the queue record.
    @discardableResult
    func removePendingItem(episodeID: String, modelContext: ModelContext) -> Task<Void, Never>? {
        guard activeItem?.episodeID != episodeID,
              let removed = entries.first(where: { $0.item.episodeID == episodeID })
        else {
            return nil
        }

        var cloudRunner: RemoteTranscriptionJobRunner?
        if removed.item.mode == .cloud,
           let jobStore = removed.deps.remoteJobStore,
           jobStore.existingReference(for: episodeID, purpose: .adDetection) != nil,
           let runner = removed.deps.remoteRunner {
            jobStore.recordUserCancelIntent(episodeID: episodeID, purpose: .adDetection)
            cloudRunner = runner
        }
        for entry in entries where entry.item.episodeID == episodeID {
            entry.launchPreparation?.cancel()
        }
        entries.removeAll { $0.item.episodeID == episodeID }

        var userCancel: Task<Void, Never>?
        if let cloudRunner {
            userCancel = startCloudUserCancel(
                episode: removed.item.episode,
                runner: cloudRunner,
                modelContext: modelContext
            )
        } else {
            removePersistedItem(episodeID: episodeID, modelContext: modelContext)
        }
        if pendingModelConsentEpisodeID == episodeID {
            pendingModelConsentEpisodeID = nil
            pendingModelConsentByteCount = nil
        }
        if entries.isEmpty, passTask == nil {
            queueState = .idle
        }
        AdFreePassBackgroundRunLog.record(
            "queue removed pending episodeID=\(episodeID) pending=\(entries.count) state=\(queueState) userCancel=\(userCancel != nil)"
        )
        return userCancel
    }

    /// Scene activation re-attaches a parked cloud item through the same
    /// reference (an auto pass enqueued meanwhile may sit ahead of it). It
    /// stays foreground-only: an automatic resume never arms the
    /// continued-processing card.
    func resumeRemoteParkedQueueIfNeeded() {
        guard queueState == .pausedInterrupted,
              activeItem == nil,
              entries.contains(where: { $0.item.remoteParkReason != nil })
        else {
            return
        }

        markHeadPresentsKeyScreen(false)
        startDrain()
    }

    private func markHeadPresentsKeyScreen(_ presents: Bool) {
        guard !entries.isEmpty else {
            return
        }
        entries[0].presentsKeyScreen = presents
    }

    /// Whether the drain holds on-device work, active or pending: every
    /// on-device item, and a cloud item once its ad detection runs here. A
    /// drain of cloud items still on the server never asks for GPU.
    var holdsOnDeviceWork: Bool {
        activeItem?.mode == .onDevice
            || isActiveCloudItemDetectingOnDevice
            || entries.contains { $0.item.mode == .onDevice }
    }

    /// Whether the active item's work is on the server alone: a cloud item
    /// before its transcript is delivered.
    var isActiveItemOnServerOnly: Bool {
        activeItem?.mode == .cloud && !isActiveCloudItemDetectingOnDevice
    }

    private var isActiveCloudItemDetectingOnDevice: Bool {
        guard activeItem?.mode == .cloud, case .analyzing = currentStage else {
            return false
        }
        return true
    }

    // MARK: - Queue drain

    private struct PassDependencies {
        let downloads: DownloadStore
        let transcriptionModels: TranscriptionModelStore
        let appleSpeechAssets: AppleSpeechAssetStore
        let transcriptions: EpisodeTranscriptionStore
        let adAnalyses: EpisodeAdAnalysisStore
        let modelContext: ModelContext
        let transcriptionEngine: AdFreePassTranscriptionEngine
        let podcastLanguageCode: String?
        let prepareBackgroundSession: @MainActor () -> Void
        let refreshSkipZones: @MainActor () async -> Int
        // Cloud detect passes only; on-device items never touch these.
        var remoteRunner: RemoteTranscriptionJobRunner?
        var remoteJobStore: RemoteTranscriptionJobStore?
        var remotePurchases: RemoteTranscriptionPurchaseStore?
    }

    private struct QueueEntry {
        var item: AdFreePassQueueItem
        let deps: PassDependencies
        var launchPreparation: Task<LaunchPreparationOutcome, Never>?
        /// Whether the listener asked for this run: a manual start, a manual
        /// re-tap or Resume. Only such a run opens the key screen when it
        /// ends needing a key; automatic, restored and environmentally
        /// resumed runs end silently, the reason shown on the queue.
        var presentsKeyScreen: Bool
    }

    private enum LaunchPreparationOutcome {
        case ready
        case skip
        case failed
    }

    private enum PassOutcome {
        case completed(zoneCount: Int)
        case failed(message: String)
        case cloudUnavailable(message: String)
        case awaitingConsent
        case interrupted(environmental: Bool)
        /// Ad detection needed the listener's own key; terminal for the
        /// item, and the drain goes on.
        case keyRequired(AnalysisKeyRequiredReason)
        /// A cloud item stopped polling while its server job may be
        /// running; it goes back to the head with this reason.
        case remoteParked(RemoteTranscriptionJobExit)
        /// The user cancelled a running cloud item; its cancel task deletes
        /// the queue record once the attempt is recorded.
        case cloudUserCancelled
        /// An unattended item stopped, or kept from starting, because it may
        /// not run now; it waits at the head and resumes by itself.
        case heldForLifecycle
        /// A new episode's item without its trusted download leaves the
        /// queue with no outcome, and the drain goes on.
        case dropped

        /// An end that a stopped transcription leaves: the store's own
        /// interruption, or a start stopped before its record existed.
        var isStoppedTranscription: Bool {
            switch self {
            case .failed, .interrupted:
                true
            case .completed, .cloudUnavailable, .awaitingConsent, .keyRequired, .remoteParked,
                 .cloudUserCancelled, .heldForLifecycle, .dropped:
                false
            }
        }
    }

    private struct OwnedTranscription {
        let transcriptions: EpisodeTranscriptionStore
        let runID: UUID
    }

    private var finishedItemCount: Int {
        drainCompletedCount + drainFailedCount
    }

    private var drainTotalItemCount: Int {
        finishedItemCount + (activeItem != nil ? 1 : 0) + entries.count
    }

    private var currentQueueContext: AdFreePassQueueContext {
        AdFreePassQueueContext(
            finishedItemCount: finishedItemCount,
            totalItemCount: max(drainTotalItemCount, 1),
            episodeTitle: activeItem?.episode.title ?? ""
        )
    }

    private func beginDrainSessionIfNeeded() {
        guard queueState == .idle, entries.isEmpty, activeItem == nil else {
            return
        }

        drainCompletedCount = 0
        drainFailedCount = 0
        drainOutcomes = []
        uiProgressMapper.reset()
        currentStage = nil
        lastInterruptedEpisodeID = nil
        pausedForEnvironmentalInterrupt = false
        pausedForLifecycleHold = false
    }

    private func resumePausedQueueIfHeadReEnqueued(
        episodeID: String,
        prepareBackgroundSession: @escaping @MainActor () -> Void
    ) {
        guard entries.first?.item.episodeID == episodeID else {
            return
        }

        switch queueState {
        case .awaitingModelConsent, .pausedInterrupted:
            pausedForEnvironmentalInterrupt = false
            scheduleResumeLaunchPreparation(
                prepareBackgroundSession: prepareBackgroundSession
            )
            startDrain()
        case .idle, .running:
            break
        }
    }

    private func scheduleResumeLaunchPreparation(
        prepareBackgroundSession: @escaping @MainActor () -> Void
    ) {
        guard !entries.isEmpty else {
            return
        }

        let episodeID = entries[0].item.episodeID
        entries[0].launchPreparation = Task {
            await Task.yield()
            await launchPreparationGate()
            await SoundLabResponsivenessDiagnostics.holdLaunchPreparationIfRequested()
            guard !Task.isCancelled else {
                return LaunchPreparationOutcome.skip
            }
            prepareBackgroundSession()
            SoundLabResponsivenessDiagnostics.mark(
                "background-session-armed",
                episodeID: episodeID
            )
            return LaunchPreparationOutcome.ready
        }
    }

    private func prepareAcceptedItemLaunch(
        item: AdFreePassQueueItem,
        dependencies: PassDependencies
    ) async -> LaunchPreparationOutcome {
        await launchPreparationGate()
        await SoundLabResponsivenessDiagnostics.holdLaunchPreparationIfRequested()
        guard !Task.isCancelled else {
            return .skip
        }

        if let userCancel = cloudUserCancels[item.episodeID] {
            // The earlier item's cancel deletes every record for the
            // episode; this item's record must land after it.
            await userCancel.value
        }

        if item.origin.isUnattended,
           await currentCompletedAnalysisVerdict(
               for: item.episodeID,
               transcriptions: dependencies.transcriptions,
               adAnalyses: dependencies.adAnalyses
           ),
           isAnalysisAttached(
               for: item.episodeID,
               transcriptions: dependencies.transcriptions,
               downloads: dependencies.downloads
           ) {
            return .skip
        }

        // Cancellation of a preparation waiting on another task does not
        // cancel that await. Removal/reset must still win before any writes.
        guard !Task.isCancelled, entries.contains(where: { $0.item == item }) else {
            return .skip
        }

        do {
            try persistItem(item, modelContext: dependencies.modelContext)
            SoundLabResponsivenessDiagnostics.mark(
                "queue-record-persisted",
                episodeID: item.episodeID
            )
        } catch {
            recordFailure(error.localizedDescription, episodeID: item.episodeID)
            return .failed
        }

        dependencies.prepareBackgroundSession()
        SoundLabResponsivenessDiagnostics.mark(
            "background-session-armed",
            episodeID: item.episodeID
        )
        AdFreePassBackgroundRunLog.record(
            "queue enqueued episodeID=\(item.episodeID) origin=\(item.origin.rawValue) mode=\(item.mode.rawValue) pending=\(entries.count) state=\(queueState)"
        )
        return .ready
    }

    private func startDrain() {
        guard passTask == nil, !entries.isEmpty else {
            return
        }

        pausedForLifecycleHold = false
        queueState = .running
        drainGeneration += 1
        let generation = drainGeneration
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await drainQueue(generation: generation)
        }
        passTask = task
        cancellationSource.start(task)
    }

    private func drainQueue(generation: Int) async {
        // Whisper-perf E1: retain the loaded runtime across items within
        // this drain only (items 2..n skip the ~4.4 s model load when the
        // model + compute profile match). Ended on every drain exit path;
        // failures, profile changes, and memory warnings drop it earlier.
        let retentionStore = entries.first?.deps.transcriptions
        retentionStore?.beginModelRetentionDrain()
        var endsRetentionOnExit = true
        defer {
            if endsRetentionOnExit, let retentionStore {
                Task { await retentionStore.endModelRetentionDrain() }
            }
        }

        while !entries.isEmpty {
            let pendingEntry = entries[0]
            let launchPreparation = await pendingEntry.launchPreparation?.value ?? .ready
            // A reset() (and possibly a successor drain) may have run during
            // the await; a drain that lost ownership must not touch queue
            // state on its way out.
            guard generation == drainGeneration else {
                return
            }
            guard !Task.isCancelled else {
                endDrain(
                    state: entries.isEmpty ? .idle : .pausedInterrupted,
                    terminal: .interrupted
                )
                return
            }
            guard entries.first?.item.episodeID == pendingEntry.item.episodeID else {
                continue
            }
            if launchPreparation == .skip {
                entries.removeFirst()
                continue
            }
            guard launchPreparation == .ready else {
                let failedEntry = entries.removeFirst()
                let message = failureMessage(for: failedEntry.item.episodeID)
                    ?? "Unable to save the ad detection request."
                drainFailedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: failedEntry.item.episodeID,
                    episodeTitle: failedEntry.item.episode.title,
                    artworkURL: failedEntry.item.episode.artworkURL,
                    kind: .failed(message: message),
                    completionDeliveryOwner: .local,
                    origin: failedEntry.item.origin
                ))
                continue
            }

            var entry = entries.removeFirst()
            if entry.item.remoteParkReason != nil {
                entry.item.remoteParkReason = nil
                persistRemoteParkReason(nil, episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            }
            activeItem = entry.item
            activeCloudJobStore = entry.item.mode == .cloud ? entry.deps.remoteJobStore : nil
            activeAdAnalyses = entry.deps.adAnalyses
            // The previous item's last stage (a failure, an upload count)
            // never presents as this item's before its first event.
            currentStage = nil
            lastPublishedStage = nil
            activeTranscriptionEngine = entry.deps.transcriptionEngine
            activeTranscriptionModelIdentity = nil
            lifecycleHoldEpisodeID = nil
            ownedTranscription = nil
            AdFreePassBackgroundRunLog.record(
                "queue item starting episodeID=\(entry.item.episodeID) origin=\(entry.item.origin.rawValue) finished=\(finishedItemCount) total=\(drainTotalItemCount)"
            )
            AdFreePassBackgroundRunLog.record(
                "transcription engine requested=\(entry.deps.transcriptionEngine.logDescription)"
            )

            var deliveryOwner = JobCompletionDeliveryOwner.local
            var outcome = await runPass(entry, deliveryOwner: &deliveryOwner)

            guard generation == drainGeneration else {
                return
            }

            // The mark, not the record, decides: a start stopped before its
            // record existed reads as a failed transcription. A cancelled
            // drain (the listener's cancel, a card expiry) is never a hold.
            if lifecycleHoldEpisodeID == entry.item.episodeID,
               outcome.isStoppedTranscription,
               !Task.isCancelled {
                outcome = .heldForLifecycle
            }
            lifecycleHoldEpisodeID = nil
            ownedTranscription = nil

            if isBackgroundProtected(),
               entry.deps.transcriptions.lastEnvironmentalComputeFallbackEpisodeID == entry.item.episodeID {
                stickyComputeProfile = .cpuOnly
            }
            activeItem = nil
            activeCloudJobStore = nil
            activeAdAnalyses = nil
            activeTranscriptionEngine = .productDefault
            activeTranscriptionModelIdentity = nil

            switch outcome {
            case .completed(let zoneCount):
                drainCompletedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .completed(zoneCount: zoneCount),
                    completionDeliveryOwner: deliveryOwner,
                    origin: entry.item.origin
                ))
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            case .failed(let message):
                drainFailedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .failed(message: message),
                    completionDeliveryOwner: deliveryOwner,
                    origin: entry.item.origin
                ))
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            case .cloudUnavailable(let message):
                drainFailedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .cloudUnavailable(message: message),
                    completionDeliveryOwner: deliveryOwner,
                    origin: entry.item.origin
                ))
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            case .awaitingConsent:
                entries.insert(entry, at: 0)
                endDrain(state: .awaitingModelConsent, terminal: .awaitingConsent)
                return
            case .interrupted(let environmental):
                if environmental {
                    entries.insert(entry, at: 0)
                    pausedForEnvironmentalInterrupt = true
                } else {
                    lastInterruptedEpisodeID = entry.item.episodeID
                    removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
                }
                endDrain(state: entries.isEmpty ? .idle : .pausedInterrupted, terminal: .interrupted)
                return
            case .heldForLifecycle:
                // A start stopped before its record read as a failure.
                clearFailure(episodeID: entry.item.episodeID)
                setStage(.interrupted)
                entries.insert(entry, at: 0)
                pausedForEnvironmentalInterrupt = true
                pausedForLifecycleHold = true
                AdFreePassBackgroundRunLog.record("queue item held episodeID=\(entry.item.episodeID) hold=lifecycle")
                endDrain(state: .pausedInterrupted, terminal: .interrupted)
                // The listener may have pressed play again, or opened the
                // app, while the transcription was still stopping. A resume
                // starts the next drain, which opens its own retention, so
                // this drain's retention ends first: ended afterwards, it
                // would close the next drain's.
                endsRetentionOnExit = false
                await retentionStore?.endModelRetentionDrain()
                resumeLifecycleHoldIfAllowed()
                return
            case .dropped:
                AdFreePassBackgroundRunLog.record("queue item dropped episodeID=\(entry.item.episodeID) reason=noTrustedDownload")
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            case .keyRequired(let reason):
                drainFailedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .keyRequired(reason),
                    completionDeliveryOwner: deliveryOwner,
                    origin: entry.item.origin
                ))
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
                // A key the listener just removed in AI Services needs no
                // key screen; the queue row says what to do.
                if entry.presentsKeyScreen,
                   !entry.deps.adAnalyses.endedForKeyRemoval(episodeID: entry.item.episodeID) {
                    onKeyRequired?(reason)
                }
            case .remoteParked(let reason):
                // Never a failure and never dropped: the paid job is still
                // the user's, and Resume re-attaches it from the head.
                var parked = entry
                parked.item.remoteParkReason = reason
                parked.launchPreparation = nil
                entries.insert(parked, at: 0)
                persistRemoteParkReason(reason, episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
                endDrain(state: .pausedInterrupted, terminal: .remoteParked(reason))
                return
            case .cloudUserCancelled:
                lastInterruptedEpisodeID = entry.item.episodeID
                endDrain(state: entries.isEmpty ? .idle : .pausedInterrupted, terminal: .cloudUserCancelled)
                return
            }
        }

        endDrain(
            state: .idle,
            terminal: .drained(completedCount: drainCompletedCount, failedCount: drainFailedCount)
        )
    }

    private func endDrain(state: AdFreePassQueueState, terminal: AdFreePassQueueTerminalOutcome) {
        queueState = state
        passTask = nil
        cancellationSource.clearTask()
        stickyComputeProfile = nil
        AdFreePassBackgroundRunLog.record(
            "queue drain ended state=\(state) terminal=\(terminal) completed=\(drainCompletedCount) failed=\(drainFailedCount) pending=\(entries.count)"
        )
        onQueueTerminal?(terminal)
    }

    /// `deliveryOwner` stays local unless a cloud item reaches its remote
    /// job run.
    private func runPass(
        _ entry: QueueEntry,
        deliveryOwner: inout JobCompletionDeliveryOwner
    ) async -> PassOutcome {
        if entry.item.mode == .cloud {
            return await runCloudPass(entry, deliveryOwner: &deliveryOwner)
        }
        let episode = entry.item.episode
        let deps = entry.deps
        // A new episode's item only reads the download its show brought in:
        // nothing here may start, resume or repeat a download for it, so a
        // file that fails trust is not downloaded again either.
        let readsDownloadOnly = entry.item.origin == .prepared
        if readsDownloadOnly, deps.downloads.completedSourceIdentity(for: episode.episodeID) == nil {
            return .dropped
        }

        let localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation
        switch deps.transcriptions.reserveLocalWork(
            for: episode.episodeID,
            allowsSameEpisodeAttachment: true
        ) {
        case .success(let value):
            localReservation = value
        case .failure(let conflict):
            return .failed(message: conflict.localizedDescription)
        }
        defer {
            deps.transcriptions.releaseLocalWork(localReservation)
        }

        do {
            if !readsDownloadOnly {
                try await ensureTrustedDownload(
                    for: episode,
                    downloads: deps.downloads,
                    modelContext: deps.modelContext
                )
            }

            // A completed transcript of this download's bytes
            // counts as done for the default path regardless of engine — skip
            // engine resolution and resource setup entirely.
            let transcriptDocument: EpisodeTranscriptDocument
            if !deps.transcriptionEngine.isExplicitOverride,
               let reusableDocument = await reusableCompletedTranscriptDocument(
                   for: episode.episodeID,
                   transcriptions: deps.transcriptions,
                   downloads: deps.downloads
               ) {
                AdFreePassBackgroundRunLog.record(
                    "transcript reuse episodeID=\(episode.episodeID) model=\(reusableDocument.modelIdentifier) version=\(reusableDocument.modelVersion)"
                )
                transcriptDocument = reusableDocument
            } else {
                let transcriptionPlan = try await resolvePlanEnsuringResources(
                    for: deps.transcriptionEngine,
                    podcastLanguageCode: deps.podcastLanguageCode,
                    transcriptionModels: deps.transcriptionModels,
                    appleSpeechAssets: deps.appleSpeechAssets,
                    modelContext: deps.modelContext
                )
                activeTranscriptionModelIdentity = transcriptionPlan.modelIdentity
                transcriptDocument = try await completedTranscript(
                    for: episode,
                    downloads: deps.downloads,
                    transcriptionModels: deps.transcriptionModels,
                    transcriptions: deps.transcriptions,
                    transcriptionPlan: transcriptionPlan,
                    localReservation: localReservation,
                    modelContext: deps.modelContext
                )
            }
            // The transcript is in hand; a hold asked for a moment too late
            // does not turn what follows into one.
            lifecycleHoldEpisodeID = nil
            try await completedAnalysis(
                for: transcriptDocument,
                transcriptions: deps.transcriptions,
                adAnalyses: deps.adAnalyses,
                allowsExplicitRetry: entry.item.origin == .manual,
                modelContext: deps.modelContext
            )
            let zoneCount = await deps.refreshSkipZones()
            clearFailure(episodeID: episode.episodeID)
            setStage(.completed(zoneCount: zoneCount))
            return .completed(zoneCount: zoneCount)
        } catch PassStop.awaitingModelConsent {
            return .awaitingConsent
        } catch PassStop.keyRequired(let reason) {
            return keyRequiredOutcome(reason, episodeID: episode.episodeID)
        } catch PassStop.interrupted {
            setStage(.interrupted)
            return .interrupted(
                environmental: consumeEnvironmentalInterruption(
                    for: episode.episodeID,
                    transcriptions: deps.transcriptions
                )
            )
        } catch is CancellationError {
            setStage(.interrupted)
            return .interrupted(
                environmental: consumeEnvironmentalInterruption(
                    for: episode.episodeID,
                    transcriptions: deps.transcriptions
                )
            )
        } catch {
            recordFailure(error.localizedDescription, episodeID: episode.episodeID)
            setStage(.failed(message: error.localizedDescription))
            return .failed(message: error.localizedDescription)
        }
    }

    /// One cloud detect item: transcript reuse first (free), then a
    /// viability precheck (never a silent mode switch), then one server
    /// transcription job, then ad detection on this device over the
    /// delivered transcript. A job an earlier build created may still carry
    /// a completed server ad block; that block is imported instead.
    private func runCloudPass(
        _ entry: QueueEntry,
        deliveryOwner: inout JobCompletionDeliveryOwner
    ) async -> PassOutcome {
        let episode = entry.item.episode
        let deps = entry.deps

        do {
            // A completed local transcript of a trusted download
            // never buys a cloud job — the analysis-only device path is free.
            // This precedes any local download, so only a download already
            // trusted can attach the transcript; anything else is left to the
            // server job's source check and exact-copy upload.
            if let reusableDocument = await reusableCompletedTranscriptDocument(
                for: episode.episodeID,
                transcriptions: deps.transcriptions,
                downloads: deps.downloads
            ) {
                AdFreePassBackgroundRunLog.record(
                    "cloud pass transcript reuse episodeID=\(episode.episodeID)"
                )
                return try await finishCloudPassWithAnalysis(
                    transcript: reusableDocument,
                    entry: entry
                )
            }

            guard let runner = deps.remoteRunner,
                  let jobStore = deps.remoteJobStore,
                  let purchases = deps.remotePurchases
            else {
                return cloudUnavailableOutcome(
                    "Cloud detection isn't available right now.",
                    episodeID: episode.episodeID
                )
            }
            if case .unavailable(let reason) = purchases.availability {
                // `.unknown` deliberately does not block: the job's own
                // bootstrap is authoritative (and the only gate that exists
                // in the dev lane).
                return cloudUnavailableOutcome(reason, episodeID: episode.episodeID)
            }
            if let duration = episode.duration,
               !purchases.estimate(durationSeconds: duration).fitsWithinHeadroom {
                return cloudUnavailableOutcome(
                    RemoteTranscriptionFailureCategory.serverRejected(.insufficientCredits).message,
                    episodeID: episode.episodeID
                )
            }
            guard let audioURL = episode.audioURL, !audioURL.isEmpty else {
                throw PassFailure(
                    RemoteTranscriptionFailureCategory.missingAudio.message
                )
            }
            if let userCancel = cloudUserCancels[episode.episodeID] {
                await userCancel.value
            }
            if jobStore.existingReference(for: episode.episodeID, purpose: .adDetection)?
                .userCancelRequestedAt != nil {
                // An earlier cancel of this episode has not reached the
                // server yet; the re-attach trigger retries it.
                return cloudUnavailableOutcome(
                    "The previous cloud detection is still being cancelled.",
                    episodeID: episode.episodeID
                )
            }
            if jobStore.hasActiveRequest, jobStore.activeEpisodeID == episode.episodeID {
                // A plain Transcribe Remotely job already owns this episode;
                // it will deliver the transcript the free path can use.
                return cloudUnavailableOutcome(
                    "A remote transcription of this episode is already running.",
                    episodeID: episode.episodeID
                )
            }

            // Snapshotted before the run: a terminal server failure clears
            // the reference before its error arrives here.
            deliveryOwner = jobStore.completionDeliveryOwner(for: episode.episodeID, purpose: .adDetection)
            let outcome = try await runner.run(
                episode: episode,
                enclosureURL: audioURL,
                purpose: .adDetection,
                modelContext: deps.modelContext,
                onEvent: { [weak self] event in
                    self?.applyCloudEvent(event)
                }
            )
            deliveryOwner = outcome.completionDeliveryOwner

            // Only a job an earlier build created asks the server for ad
            // detection; its completed block is as good as a device run.
            if case .completed(let success) = outcome.adAnalysis {
                do {
                    let analysisDocument = try await EpisodeRemoteAdAnalysisMapper.documentOffCaller(
                        from: success,
                        transcript: outcome.document,
                        requestID: outcome.jobID
                    )
                    try Task.checkCancellation()
                    try deps.adAnalyses.importCompletedAnalysis(
                        analysisDocument,
                        modelContext: deps.modelContext
                    )
                    let zoneCount = await deps.refreshSkipZones()
                    clearFailure(episodeID: episode.episodeID)
                    setStage(.completed(zoneCount: zoneCount))
                    return .completed(zoneCount: zoneCount)
                } catch {
                    AdFreePassBackgroundRunLog.record(
                        "cloud analysis import rejected episodeID=\(episode.episodeID); detecting on this device"
                    )
                }
            }
            // No block, a failed one, or one the mapper refused: the
            // transcript is durably imported, so ad detection runs on this
            // device over it.
            return try await finishCloudPassWithAnalysis(
                transcript: outcome.document,
                entry: entry
            )
        } catch PassStop.keyRequired(let reason) {
            return keyRequiredOutcome(reason, episodeID: episode.episodeID)
        } catch PassStop.awaitingModelConsent {
            return .awaitingConsent
        } catch PassStop.interrupted {
            setStage(.interrupted)
            return .interrupted(environmental: false)
        } catch is CancellationError {
            // Local cancellation never cancels the server job by itself. A
            // user request (its intent already persisted) resolves it
            // through the runner's user-cancel path; expiration and every
            // other stop park the reference so the paid work re-attaches.
            let reason = cancellationSource.lastCancellationReason
            if reason == .userRequest, let runner = deps.remoteRunner {
                startCloudUserCancel(episode: episode, runner: runner, modelContext: deps.modelContext)
                setStage(.interrupted)
                return .cloudUserCancelled
            }
            guard Self.mayHoldServerJob(episodeID: episode.episodeID, jobStore: deps.remoteJobStore) else {
                // Before any create, or after the job delivered and only the
                // free on-device analysis was left: nothing runs remotely.
                setStage(.interrupted)
                return .interrupted(environmental: false)
            }
            if reason == .sessionExpiration {
                recordSessionEvent(.sessionExpired, episodeID: episode.episodeID, jobStore: deps.remoteJobStore)
            }
            deps.remoteJobStore?.recordExit(.parked, episodeID: episode.episodeID, purpose: .adDetection)
            setStage(.cloudParked(.parked))
            return .remoteParked(.parked)
        } catch let error as RemoteTranscriptionJobRunError {
            if let reason = Self.parkReason(for: error),
               Self.mayHoldServerJob(episodeID: episode.episodeID, jobStore: deps.remoteJobStore) {
                // Keep the item at the head with Resume. With no create
                // attempted there is no job, and the cloud-unavailable
                // outcome below stays honest.
                setStage(.cloudParked(reason))
                return .remoteParked(reason)
            }
            if Self.isCloudUnavailableRunError(error) {
                return cloudUnavailableOutcome(
                    Self.cloudFailureMessage(for: error),
                    episodeID: episode.episodeID
                )
            }
            let message = Self.cloudFailureMessage(for: error)
            recordFailure(message, episodeID: episode.episodeID)
            setStage(.failed(message: message))
            return .failed(message: message)
        } catch {
            recordFailure(error.localizedDescription, episodeID: episode.episodeID)
            setStage(.failed(message: error.localizedDescription))
            return .failed(message: error.localizedDescription)
        }
    }

    /// Shared tail of the cloud pass: run (or reuse) the device ad detection
    /// over a completed transcript. It stops with the pass like an
    /// on-device item's.
    private func finishCloudPassWithAnalysis(
        transcript: EpisodeTranscriptDocument,
        entry: QueueEntry
    ) async throws -> PassOutcome {
        try await completedAnalysis(
            for: transcript,
            transcriptions: entry.deps.transcriptions,
            adAnalyses: entry.deps.adAnalyses,
            allowsExplicitRetry: entry.item.origin == .manual,
            modelContext: entry.deps.modelContext
        )
        let zoneCount = await entry.deps.refreshSkipZones()
        clearFailure(episodeID: entry.item.episodeID)
        setStage(.completed(zoneCount: zoneCount))
        return .completed(zoneCount: zoneCount)
    }

    /// The user cancel of a cloud item, shared by the running item and a
    /// pending one: the runner resolves the job and sends at most one
    /// `/cancel`, then the queue record goes. A death in between leaves a
    /// record the next launch drops and an intent the re-attach trigger
    /// resolves.
    @discardableResult
    private func startCloudUserCancel(
        episode: EpisodeListItemSnapshot,
        runner: RemoteTranscriptionJobRunner,
        modelContext: ModelContext
    ) -> Task<Void, Never> {
        let episodeID = episode.episodeID
        if let inFlight = cloudUserCancels[episodeID] {
            return inFlight
        }
        let userCancel = Task { [weak self] in
            _ = await runner.cancelServerJob(episodeID: episodeID, purpose: .adDetection, replaying: episode)
            self?.removePersistedItem(episodeID: episodeID, modelContext: modelContext)
            self?.cloudUserCancels[episodeID] = nil
        }
        cloudUserCancels[episodeID] = userCancel
        return userCancel
    }

    /// A create may have reached the server, so a paid job may be running.
    private static func mayHoldServerJob(episodeID: String, jobStore: RemoteTranscriptionJobStore?) -> Bool {
        guard let reference = jobStore?.existingReference(for: episodeID, purpose: .adDetection) else {
            return false
        }
        return reference.createState != .prepared
    }

    private static func parkReason(for error: RemoteTranscriptionJobRunError) -> RemoteTranscriptionJobExit? {
        switch error {
        case .connectionLost:
            .connectionLost
        case .localRequestFailed:
            .localRequestFailed
        default:
            nil
        }
    }

    private func recordSessionEvent(
        _ kind: RemoteJobDiagnosticEvent.Kind,
        episodeID: String,
        jobStore: RemoteTranscriptionJobStore?
    ) {
        guard let jobStore else {
            return
        }
        let reference = jobStore.existingReference(for: episodeID, purpose: .adDetection)
        jobStore.diagnostics.record(RemoteJobDiagnosticEvent(
            component: .backgroundSession,
            kind: kind,
            episodeID: episodeID,
            jobID: reference?.jobID,
            clientRequestID: reference?.clientRequestID,
            purpose: .adDetection
        ))
    }

    private func cloudUnavailableOutcome(_ message: String, episodeID: String) -> PassOutcome {
        recordFailure(message, episodeID: episodeID)
        setStage(.cloudUnavailable(message: message))
        return .cloudUnavailable(message: message)
    }

    private func applyCloudEvent(_ event: RemoteTranscriptionJobEvent) {
        switch event {
        case .downloading:
            setStage(.downloadingEpisode)
        case .queuedRemotely:
            setStage(.cloudQueued)
        case .verifying:
            setStage(.cloudVerifying)
        case .uploadingExactCopy(let completedParts, let totalParts):
            setStage(.cloudUploadingExactCopy(completedParts: completedParts, totalParts: totalParts))
        case .waitingForCredits:
            setStage(.cloudWaitingForCredits)
        case .processing(let progress) where progress.stage == .finalizing:
            setStage(.cloudFinishing)
        case .processing(let progress):
            setStage(.cloudTranscribing(progress))
        case .detectingAds, .saving:
            // A job an earlier build created still runs server ad detection
            // before it delivers; either way the transcript is finishing.
            setStage(.cloudFinishing)
        }
    }

    /// Failures where "Detect on this device instead" is the honest recovery
    /// (credits, capacity, kill switch, unreachable service) — never a
    /// silent mode switch, always the explicit one-tap fallback.
    private static func isCloudUnavailableRunError(_ error: RemoteTranscriptionJobRunError) -> Bool {
        switch error {
        case .serviceUnavailable, .connectionLost, .localRequestFailed:
            true
        case .serverRejected(let code):
            code == .featureDisabled
                || code == .insufficientCredits
                || code == .rateLimited
        case .downloadFailed, .remoteCancelled, .mismatchLocalFallback, .resultInvalid,
             .acknowledgedWithoutLocalImport:
            false
        }
    }

    private static func cloudFailureMessage(for error: RemoteTranscriptionJobRunError) -> String {
        switch error {
        case .mismatchLocalFallback:
            "The server's audio didn't match this device's copy."
        case .remoteCancelled:
            "The server ended the cloud detection job."
        default:
            error.failureCategory.message
        }
    }

    // MARK: - Presentation helpers

    private func queuedPresentation(for episodeID: String) -> EpisodeAdFreePassPresentation? {
        guard let index = entries.firstIndex(where: { $0.item.episodeID == episodeID }) else {
            return nil
        }
        if let reason = entries[index].item.remoteParkReason {
            return .remoteParked(reason)
        }

        switch queueState {
        case .running:
            return .queued(ahead: index + (activeItem != nil ? 1 : 0))
        case .pausedInterrupted, .awaitingModelConsent, .idle:
            // Paused heads fall through to store-derived presentation so
            // interrupted/consent copy and resume actions surface unchanged.
            return index == 0 ? nil : .queued(ahead: index)
        }
    }

    /// True while a cloud detect item is running or pending for the episode;
    /// gates Transcribe Remotely (the cloud pass delivers the transcript).
    func hasActiveOrQueuedCloudItem(for episodeID: String) -> Bool {
        if let activeItem, activeItem.episodeID == episodeID, activeItem.mode == .cloud {
            return true
        }
        return entries.contains { $0.item.episodeID == episodeID && $0.item.mode == .cloud }
    }

    func hasCurrentCompletedAnalysis(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) -> Bool {
        completedAnalysisVerdictIfAvailable(
            for: episodeID,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses
        ) ?? false
    }

    private func completedAnalysisVerdictIfAvailable(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) -> Bool? {
        guard let analysisRecord = adAnalyses.record(for: episodeID),
              analysisRecord.state == .completed,
              let transcriptRecord = transcriptions.record(for: episodeID),
              transcriptRecord.state == .completed
        else {
            return false
        }

        // Answering for real means decoding + fingerprinting the full
        // transcript document, which scales with episode length — done
        // synchronously here it froze scrolling for every realized row with
        // a completed analysis. The verdict is computed off-main once per
        // (transcript, analysis) revision and cached; until it lands,
        // readers see `false`, which only under-offers "Ads Detected" for
        // the moments before a menu could actually be presented. Gates that
        // must not double-run passes use
        // `currentCompletedAnalysisVerdict` instead.
        let transcriptStamp = transcriptRecord.updatedAt
        let analysisStamp = analysisRecord.updatedAt
        if let verdict = completedAnalysisVerdictsByEpisodeID[episodeID],
           verdict.transcriptRecordUpdatedAt == transcriptStamp,
           verdict.analysisRecordUpdatedAt == analysisStamp {
            return verdict.isCurrent
        }

        scheduleCompletedAnalysisVerdictCompute(
            episodeID: episodeID,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses
        )
        return nil
    }

    /// Definitive variant for no-double-run gates. A cache miss loads both
    /// documents and fingerprints off the caller's actor.
    func currentCompletedAnalysisVerdict(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) async -> Bool {
        guard let analysisRecord = adAnalyses.record(for: episodeID),
              analysisRecord.state == .completed,
              let transcriptRecord = transcriptions.record(for: episodeID),
              transcriptRecord.state == .completed
        else {
            return false
        }

        let transcriptStamp = transcriptRecord.updatedAt
        let analysisStamp = analysisRecord.updatedAt
        if let verdict = completedAnalysisVerdictsByEpisodeID[episodeID],
           verdict.transcriptRecordUpdatedAt == transcriptStamp,
           verdict.analysisRecordUpdatedAt == analysisStamp {
            return verdict.isCurrent
        }

        SoundLabResponsivenessDiagnostics.mark(
            "verdict-documents-load-begin",
            episodeID: episodeID
        )
        async let transcriptLoad = try? transcriptions.loadDocument(for: episodeID)
        async let analysisLoad = try? adAnalyses.loadDocument(for: episodeID)
        let (transcriptDocument, analysisDocument) = await (transcriptLoad, analysisLoad)
        SoundLabResponsivenessDiagnostics.mark(
            "verdict-documents-load-end",
            episodeID: episodeID
        )

        var isCurrent = false
        if let transcriptDocument, let analysisDocument {
            isCurrent = await adAnalyses.isCurrentAnalysisDocumentOffCaller(
                analysisDocument,
                for: transcriptDocument
            )
        }
        if transcriptions.record(for: episodeID)?.updatedAt == transcriptStamp,
           adAnalyses.record(for: episodeID)?.updatedAt == analysisStamp {
            completedAnalysisVerdictsByEpisodeID[episodeID] = CompletedAnalysisVerdict(
                transcriptRecordUpdatedAt: transcriptStamp,
                analysisRecordUpdatedAt: analysisStamp,
                isCurrent: isCurrent
            )
        }
        return isCurrent
    }

    private struct CompletedAnalysisVerdict {
        let transcriptRecordUpdatedAt: Date
        let analysisRecordUpdatedAt: Date
        let isCurrent: Bool
    }

    private var completedAnalysisVerdictsByEpisodeID: [String: CompletedAnalysisVerdict] = [:]
    @ObservationIgnored private var completedAnalysisVerdictComputesInFlight: Set<String> = []

    private func scheduleCompletedAnalysisVerdictCompute(
        episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) {
        guard !completedAnalysisVerdictComputesInFlight.contains(episodeID) else {
            return
        }
        completedAnalysisVerdictComputesInFlight.insert(episodeID)
        Task { [weak self] in
            guard let self else {
                return
            }
            _ = await self.currentCompletedAnalysisVerdict(
                for: episodeID,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses
            )
            self.completedAnalysisVerdictComputesInFlight.remove(episodeID)
        }
    }

    // MARK: - Persistence

    private var persistedSequenceBounds: (low: Int, high: Int) {
        let sequences = entries.map(\.item.sequence) + (activeItem.map { [$0.sequence] } ?? [])
        return (low: sequences.min() ?? 0, high: sequences.max() ?? 0)
    }

    private func nextSequence(front: Bool) -> Int {
        let bounds = persistedSequenceBounds
        return front ? bounds.low - 1 : bounds.high + 1
    }

    private func persistItem(_ item: AdFreePassQueueItem, modelContext: ModelContext) throws {
        let record = AdFreePassQueueItemRecord(
            episodeID: item.episodeID,
            podcastID: item.episode.podcastID,
            originRawValue: item.origin.rawValue,
            enqueuedAt: item.enqueuedAt,
            sequence: item.sequence,
            modeRawValue: item.mode.rawValue
        )
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(record)
            throw error
        }
    }

    private func persistRemoteParkReason(
        _ reason: RemoteTranscriptionJobExit?,
        episodeID: String,
        modelContext: ModelContext
    ) {
        let descriptor = FetchDescriptor<AdFreePassQueueItemRecord>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        guard let records = try? modelContext.fetch(descriptor), !records.isEmpty else {
            return
        }

        for record in records {
            record.remoteParkReasonRawValue = reason?.rawValue ?? ""
        }
        try? modelContext.save()
    }

    private func removePersistedItem(episodeID: String, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<AdFreePassQueueItemRecord>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        guard let records = try? modelContext.fetch(descriptor), !records.isEmpty else {
            return
        }

        for record in records {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    // MARK: - Pass steps

    /// A completed transcript is reused only while it is attached to the
    /// trusted download: one made from other bytes could never align with
    /// the download's playback, so its analysis would be wasted (D1). The
    /// download can be removed or replaced while the document loads, so the
    /// loaded document is held to it again.
    private func reusableCompletedTranscriptDocument(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        downloads: DownloadStore
    ) async -> EpisodeTranscriptDocument? {
        guard let record = transcriptions.record(for: episodeID),
              record.state == .completed,
              isTranscriptAttached(sourceFileSHA256: record.sourceFileSHA256, episodeID: episodeID, downloads: downloads)
        else {
            return nil
        }
        SoundLabResponsivenessDiagnostics.mark(
            "transcript-document-load-begin",
            episodeID: episodeID
        )
        let document = try? await transcriptions.loadDocument(for: episodeID)
        SoundLabResponsivenessDiagnostics.mark(
            "transcript-document-load-end",
            episodeID: episodeID
        )
        guard let document,
              isTranscriptAttached(sourceFileSHA256: document.sourceFileSHA256, episodeID: episodeID, downloads: downloads)
        else {
            return nil
        }
        return document
    }

    /// Whether a transcript of the bytes `sourceFileSHA256` names is
    /// attached to the episode's trusted download as it is now. A detached
    /// one is logged.
    private func isTranscriptAttached(
        sourceFileSHA256: String,
        episodeID: String,
        downloads: DownloadStore
    ) -> Bool {
        let trustedDownloadSHA256 = downloads.completedSourceIdentity(for: episodeID)?.sha256
        let attachment = EpisodeAdAnalysisAttachment.resolve(
            transcriptSourceSHA256: sourceFileSHA256,
            trustedDownloadSHA256: trustedDownloadSHA256
        )
        guard attachment == .attached else {
            AdFreePassBackgroundRunLog.record(
                "transcript detached episodeID=\(episodeID) transcriptSHA=\(sourceFileSHA256) downloadSHA=\(trustedDownloadSHA256 ?? "none")"
            )
            return false
        }
        return true
    }

    /// Makes the episode's completed download trusted before the pass
    /// decides anything. Each decision after it reads the download store
    /// afresh: the download can change at every suspension.
    private func ensureTrustedDownload(
        for episode: EpisodeListItemSnapshot,
        downloads: DownloadStore,
        modelContext: ModelContext
    ) async throws {
        setStage(.downloadingEpisode)

        do {
            _ = try await TrustedCompletedDownload.ensure(
                for: episode,
                downloads: downloads,
                modelContext: modelContext,
                onWaitStarted: { try Task.checkCancellation() }
            )
        } catch DownloadStore.CompletedDownloadError.fileMissing {
            throw EpisodeDownloadError.missingDownloadedFile
        } catch let DownloadStore.CompletedDownloadError.notCompleted(state, errorMessage) {
            let message = state == .paused
                ? "Download paused."
                : errorMessage ?? EpisodeDownloadError.missingDownloadedFile.localizedDescription
            throw PassFailure(message)
        }
    }

    private func ensureModelReady(_ transcriptionModels: TranscriptionModelStore) async throws {
        var didStartInstall = false

        while true {
            try Task.checkCancellation()

            let modelChangeSequence = transcriptionModels.changeSequence
            switch transcriptionModels.state {
            case .installed:
                return
            case .repairAvailable, .notInstalled, .unknown:
                didStartInstall = try await installModelIfConsentedOrStop(transcriptionModels)
            case .failed(let message):
                guard !didStartInstall else {
                    throw PassFailure(message)
                }
                didStartInstall = try await installModelIfConsentedOrStop(transcriptionModels)
            case .installing(let progress):
                setStage(.installingModel(progress))
            case .checking, .deleting:
                break
            }

            try await transcriptionModels.waitForChange(after: modelChangeSequence)
        }
    }

    private func resolvePlanEnsuringResources(
        for engine: AdFreePassTranscriptionEngine,
        podcastLanguageCode: String?,
        transcriptionModels: TranscriptionModelStore,
        appleSpeechAssets: AppleSpeechAssetStore,
        modelContext: ModelContext
    ) async throws -> EpisodeTranscriptionPlan {
        let resolver = EpisodeTranscriptionPlanResolver(
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            prefersRevocationDurableEngine: !BGTaskSchedulerAdFreePassScheduler().supportsGPUResources
        )

        switch engine {
        case .selectedWhisperModel, .whisperTiny:
            try await ensureModelReady(transcriptionModels)
        case .productDefault, .appleSpeech:
            break
        }

        let assetStageTask = engine == .productDefault
            ? observeAssetInstallStages(appleSpeechAssets)
            : nil
        defer {
            assetStageTask?.cancel()
        }

        do {
            return try await resolver.resolve(
                requestedEngine: engine,
                podcastLanguageCode: podcastLanguageCode
            )
        } catch EpisodeTranscriptionError.missingSpeechModel where engine == .productDefault {
            // Whisper fallback with no installed model: pin the tiny model
            // (the fallback target) and run the existing
            // consent/install flow, then re-resolve.
            if transcriptionModels.selectedChoice != .fastTinyEnglish {
                _ = transcriptionModels.setSelectedChoice(.fastTinyEnglish, modelContext: modelContext)
            }
            try await ensureModelReady(transcriptionModels)
            return try await resolver.resolve(
                requestedEngine: engine,
                podcastLanguageCode: podcastLanguageCode
            )
        }
    }

    private func observeAssetInstallStages(
        _ appleSpeechAssets: AppleSpeechAssetStore
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let sequence = appleSpeechAssets.changeSequence
                if case .installing(_, let fractionCompleted) = appleSpeechAssets.state {
                    self?.setStage(.installingSpeechAssets(fractionCompleted: fractionCompleted))
                }
                do {
                    try await appleSpeechAssets.waitForChange(after: sequence)
                } catch {
                    return
                }
            }
        }
    }

    private func completedTranscript(
        for episode: EpisodeListItemSnapshot,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptionPlan: EpisodeTranscriptionPlan,
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation,
        modelContext: ModelContext
    ) async throws -> EpisodeTranscriptDocument {
        var didStartTranscription = false

        while true {
            try Task.checkCancellation()

            let modelChangeSequence = transcriptionModels.changeSequence
            let transcriptionChangeSequence = transcriptions.changeSequence
            // Re-read every turn: the download can be removed or replaced
            // while the pass waits, and only a transcript of the bytes it
            // now holds counts.
            let downloadRecord = downloads.record(for: episode.episodeID)
            let state = transcriptions.jobState(
                for: episode.episodeID,
                downloadRecord: downloadRecord,
                modelState: transcriptionModels.state,
                modelIdentity: transcriptionPlan.isEngineStrict ? transcriptionPlan.modelIdentity : nil,
                requiresInstalledWhisperModel: transcriptionPlan.requiresInstalledWhisperModel,
                sourceMatch: .trusted(sha256: downloads.completedSourceIdentity(for: episode.episodeID)?.sha256)
            )
            switch state {
            case .completed(let record):
                let admittedSourceSHA256 = record.sourceFileSHA256
                SoundLabResponsivenessDiagnostics.mark(
                    "transcript-document-load-begin",
                    episodeID: episode.episodeID
                )
                guard let document = try? await transcriptions.loadDocument(
                    for: episode.episodeID
                ) else {
                    throw EpisodeTranscriptionError.transcriptDocumentMissing
                }
                SoundLabResponsivenessDiagnostics.mark(
                    "transcript-document-load-end",
                    episodeID: episode.episodeID
                )
                if isTranscriptAttached(
                    sourceFileSHA256: document.sourceFileSHA256,
                    episodeID: episode.episodeID,
                    downloads: downloads
                ) {
                    return document
                }
                // Go round again only when the download moved during the
                // load: the next turn no longer admits this record, and only
                // the pass's own single transcription can make one it
                // admits. A download that held still means the document is
                // not the transcript its record describes.
                guard downloads.completedSourceIdentity(for: episode.episodeID)?.sha256 != admittedSourceSHA256 else {
                    throw EpisodeTranscriptionError.transcriptDocumentMissing
                }
                continue
            case .running(let progress):
                setStage(.transcribing(progress))
                break
            case .interrupted:
                try await startTranscriptionOrThrowOnSecondAttempt(
                    secondPassError: PassStop.interrupted,
                    didStartTranscription: &didStartTranscription,
                    episode: episode,
                    downloadRecord: downloadRecord,
                    downloads: downloads,
                    transcriptionModels: transcriptionModels,
                    transcriptions: transcriptions,
                    transcriptionPlan: transcriptionPlan,
                    localReservation: localReservation,
                    modelContext: modelContext
                )
            case .ready, .failed, .cancelled:
                try await startTranscriptionOrThrowOnSecondAttempt(
                    secondPassError: secondAttemptError(
                        for: state,
                        episodeID: episode.episodeID,
                        transcriptions: transcriptions
                    ),
                    didStartTranscription: &didStartTranscription,
                    episode: episode,
                    downloadRecord: downloadRecord,
                    downloads: downloads,
                    transcriptionModels: transcriptionModels,
                    transcriptions: transcriptions,
                    transcriptionPlan: transcriptionPlan,
                    localReservation: localReservation,
                    modelContext: modelContext
                )
            case .downloadRequired:
                throw EpisodeTranscriptionError.downloadNotComplete
            case .modelRequired:
                throw EpisodeTranscriptionError.missingSpeechModel
            case .modelBusy:
                try await transcriptionModels.waitForChange(after: modelChangeSequence)
                continue
            case .unavailable:
                throw PassFailure(FailureMessage.transcriptUnavailable)
            }

            try await transcriptions.waitForChange(after: transcriptionChangeSequence)
        }
    }

    private func completedAnalysis(
        for transcriptDocument: EpisodeTranscriptDocument,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        allowsExplicitRetry: Bool,
        modelContext: ModelContext
    ) async throws {
        if !allowsExplicitRetry, let blocked = try await adAnalyses.automaticReplayError(for: transcriptDocument) { throw blocked }
        let episodeID = transcriptDocument.episodeID
        let progressUpdates = followAnalysisProgress(for: episodeID, adAnalyses: adAnalyses)
        defer {
            progressUpdates.cancel()
        }
        var didStartAnalysis = false

        do {
            while true {
                try Task.checkCancellation()

                let analysisChangeSequence = adAnalyses.changeSequence
                if adAnalyses.isRunning(for: episodeID) {
                    publishAnalyzing(steps: analysisSteps(for: episodeID, adAnalyses: adAnalyses))
                } else if let record = adAnalyses.record(for: episodeID) {
                    switch record.state {
                    case .queued, .running:
                        // No run holds it: a cancelled run leaves its record
                        // running until a start (or the next launch) moves
                        // it on.
                        try startAnalysisOrThrowOnSecondAttempt(
                            didStartAnalysis: &didStartAnalysis,
                            transcriptDocument: transcriptDocument,
                            transcriptions: transcriptions,
                            adAnalyses: adAnalyses,
                            allowsExplicitRetry: allowsExplicitRetry,
                            modelContext: modelContext
                        )
                    case .completed:
                        if await adAnalyses.hasCurrentCompletedAnalysis(
                            for: transcriptDocument
                        ) {
                            return
                        }
                        try startAnalysisOrThrowOnSecondAttempt(
                            didStartAnalysis: &didStartAnalysis,
                            transcriptDocument: transcriptDocument,
                            transcriptions: transcriptions,
                            adAnalyses: adAnalyses,
                            allowsExplicitRetry: allowsExplicitRetry,
                            modelContext: modelContext
                        )
                    case .failed:
                        guard !didStartAnalysis else {
                            if let reason = record.failureKind?.keyRequiredReason {
                                throw PassStop.keyRequired(reason)
                            }
                            throw analysisPassFailure(
                                episodeID: episodeID,
                                adAnalyses: adAnalyses,
                                recorded: record.errorMessage ?? adAnalyses.lastErrorMessage(for: episodeID)
                            )
                        }
                        try startAnalysisOrThrowOnSecondAttempt(
                            didStartAnalysis: &didStartAnalysis,
                            transcriptDocument: transcriptDocument,
                            transcriptions: transcriptions,
                            adAnalyses: adAnalyses,
                            allowsExplicitRetry: allowsExplicitRetry,
                            modelContext: modelContext
                        )
                    }
                } else {
                    if let unavailableMessage = adAnalyses.analysisStartUnavailableMessage {
                        throw PassFailure(unavailableMessage)
                    }
                    guard !didStartAnalysis else {
                        throw analysisPassFailure(
                            episodeID: episodeID,
                            adAnalyses: adAnalyses,
                            recorded: adAnalyses.lastErrorMessage(for: episodeID)
                        )
                    }
                    try startAnalysisOrThrowOnSecondAttempt(
                        didStartAnalysis: &didStartAnalysis,
                        transcriptDocument: transcriptDocument,
                        transcriptions: transcriptions,
                        adAnalyses: adAnalyses,
                        allowsExplicitRetry: allowsExplicitRetry,
                        modelContext: modelContext
                    )
                }

                try await adAnalyses.waitForChange(after: analysisChangeSequence)
            }
        } catch let error as CancellationError {
            // The store owns the run, not the pass: stop its sends with the
            // pass. An expired card keeps the run resumable.
            cancelActiveAnalysisRun(
                reason: cancellationSource.lastCancellationReason == .sessionExpiration ? .expiration : .listener
            )
            throw error
        }
    }

    /// Every start is automatic for the store: the key screen shows once
    /// per drain from the drain itself, whatever started the item.
    private func startAnalysisOrThrowOnSecondAttempt(
        didStartAnalysis: inout Bool,
        transcriptDocument: EpisodeTranscriptDocument,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        allowsExplicitRetry: Bool,
        modelContext: ModelContext
    ) throws {
        let episodeID = transcriptDocument.episodeID
        guard !didStartAnalysis else {
            if let reason = adAnalyses.record(for: episodeID)?.failureKind?.keyRequiredReason {
                throw PassStop.keyRequired(reason)
            }
            throw analysisPassFailure(
                episodeID: episodeID,
                adAnalyses: adAnalyses,
                recorded: adAnalyses.lastErrorMessage(for: episodeID)
            )
        }

        adAnalyses.startAnalysis(
            transcript: transcriptDocument,
            transcriptState: transcriptions.record(for: episodeID)?.state,
            retryFailed: allowsExplicitRetry,
            presentsKeyScreen: false,
            modelContext: modelContext
        )
        didStartAnalysis = true
        publishAnalyzing(steps: analysisSteps(for: episodeID, adAnalyses: adAnalyses))
    }

    /// How a pass reports a failed run: the card's copy for the kinds that
    /// have it, or else what the run recorded.
    private func analysisPassFailure(
        episodeID: String,
        adAnalyses: EpisodeAdAnalysisStore,
        recorded: String?
    ) -> PassFailure {
        if let kind = adAnalyses.record(for: episodeID)?.failureKind, kind.passUsesCardCopy {
            return PassFailure(EpisodePipelineState.analysisFailedMessage(for: kind))
        }
        return PassFailure(recorded ?? FailureMessage.analysisFailed)
    }

    private func analysisSteps(
        for episodeID: String,
        adAnalyses: EpisodeAdAnalysisStore
    ) -> EpisodeAdFreePassAnalysisSteps? {
        adAnalyses.analysisProgress(for: episodeID).map(EpisodeAdFreePassAnalysisSteps.init)
    }

    /// Publishes the analyzing stage with the run's steps. A run that has
    /// not counted its steps yet, or has just ended, keeps the steps shown.
    private func publishAnalyzing(steps: EpisodeAdFreePassAnalysisSteps?) {
        if steps == nil, case .analyzing(.some) = lastPublishedStage {
            return
        }
        setStage(.analyzing(steps: steps))
    }

    /// Follows the store's step count while the pass waits on its run, so
    /// the queue and the card move with each answered step.
    private func followAnalysisProgress(
        for episodeID: String,
        adAnalyses: EpisodeAdAnalysisStore
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await steps in Observations({
                adAnalyses.analysisProgress(for: episodeID).map(EpisodeAdFreePassAnalysisSteps.init)
            }) {
                guard !Task.isCancelled, let self else {
                    return
                }
                guard case .analyzing = lastPublishedStage else {
                    continue
                }
                publishAnalyzing(steps: steps)
            }
        }
    }

    /// The item ends needing the listener's key: the card names the reason
    /// and the drain goes on.
    private func keyRequiredOutcome(_ reason: AnalysisKeyRequiredReason, episodeID: String) -> PassOutcome {
        let message = EpisodePipelineState.analysisFailedMessage(for: EpisodeAnalysisFailureKind(keyRequired: reason))
        recordFailure(message, episodeID: episodeID)
        setStage(.failed(message: message))
        return .keyRequired(reason)
    }

    private func installModelIfConsentedOrStop(
        _ transcriptionModels: TranscriptionModelStore
    ) async throws -> Bool {
        // Nobody is there to consent for a new episode's item, and waiting
        // on consent would stall every item behind it.
        if activeItem?.origin == .prepared {
            throw EpisodeTranscriptionError.missingSpeechModel
        }
        guard pendingModelConsentEpisodeID == activeEpisodeID else {
            let byteCount = try await transcriptionModels.selectedModelRemoteByteCount()
            pendingModelConsentByteCount = byteCount
            pendingModelConsentEpisodeID = activeEpisodeID
            setStage(.awaitingModelDownloadConsent(byteCount: byteCount))
            throw PassStop.awaitingModelConsent
        }

        pendingModelConsentEpisodeID = nil
        pendingModelConsentByteCount = nil
        transcriptionModels.installPinnedModel()
        return true
    }

    private func startTranscriptionOrThrowOnSecondAttempt(
        secondPassError: @autoclosure () -> any Error,
        didStartTranscription: inout Bool,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord?,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptionPlan: EpisodeTranscriptionPlan,
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation,
        modelContext: ModelContext
    ) async throws {
        guard !didStartTranscription else {
            throw secondPassError()
        }
        // A drain that lost its reason to run while it downloaded or
        // analysed must not start transcribing with nobody there.
        if activeItem?.origin.isUnattended == true, !allowsUnattendedWork() {
            lifecycleHoldEpisodeID = episode.episodeID
            AdFreePassBackgroundRunLog.record("queue admission refused episodeID=\(episode.episodeID)")
            throw PassStop.interrupted
        }

        try await startTranscription(
            episode,
            downloadRecord: downloadRecord,
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            transcriptions: transcriptions,
            transcriptionPlan: transcriptionPlan,
            localReservation: localReservation,
            modelContext: modelContext
        )
        didStartTranscription = true
    }

    private func startTranscription(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord?,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptionPlan: EpisodeTranscriptionPlan,
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation,
        modelContext: ModelContext
    ) async throws {
        guard let downloadRecord else {
            throw EpisodeTranscriptionError.missingDownloadedFile
        }
        guard let localFileURL = downloads.localFileURL(for: downloadRecord),
              downloads.downloadedFileExists(for: downloadRecord)
        else {
            try? downloads.markDownloadedFileMissing(downloadRecord, modelContext: modelContext)
            throw EpisodeTranscriptionError.missingDownloadedFile
        }

        // After a classified cpuOnly fallback inside a protected
        // drain, subsequent whisper items skip the doomed default attempt.
        let initialComputeProfile: OpenCastTranscriptionComputeProfile =
            transcriptionPlan.runEngine == .whisper
                ? initialWhisperComputeProfile
                : .backgroundSafe

        // A replacement keeps the prior transcript until it completes: a
        // cancel or failure restores it, and an interruption restores it and
        // keeps the partial to resume from (R5).
        let replacesCompletedTranscript = transcriptions.record(for: episode.episodeID)?.state == .completed
        let didStart = transcriptions.startTranscription(
            episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            engine: transcriptionPlan.runEngine,
            modelIdentity: transcriptionPlan.modelIdentity,
            languageCode: transcriptionPlan.languageCode,
            runLanguageCode: transcriptionPlan.runLanguageCode,
            initialComputeProfile: initialComputeProfile,
            priorCompletedTranscript: replacesCompletedTranscript ? .preserveKeepingInterruptedPartial : .discard,
            priority: Self.transcriptionPriority(for: activeItem?.origin),
            localReservation: localReservation,
            modelContext: modelContext
        )
        if didStart, let runID = transcriptions.activeRunID {
            ownedTranscription = OwnedTranscription(transcriptions: transcriptions, runID: runID)
        }
    }

    /// Work nobody is waiting on runs at `.utility`, the priority measured
    /// stall-free beside playback; a manual item keeps the inherited one.
    private static func transcriptionPriority(for origin: AdFreePassQueueOrigin?) -> TaskPriority? {
        origin?.isUnattended == true ? .utility : nil
    }

    /// What the pass reports when its own transcription left the episode
    /// still to transcribe. A replacement that stopped restored the prior
    /// transcript, which reads `.ready` against the download: the store's
    /// note says whether that stop was an interruption or a cancel, which
    /// reads as a first transcription's cancel does, and otherwise the
    /// failure it recorded says why. Built only when it is thrown, so the
    /// cancel note is read once.
    private func secondAttemptError(
        for state: EpisodeTranscriptionJobState,
        episodeID: String,
        transcriptions: EpisodeTranscriptionStore
    ) -> any Error {
        guard case .ready = state else {
            return PassFailure(transcriptionFailureMessage(state))
        }
        if transcriptions.interruptedReplacement(for: episodeID) != nil {
            return PassStop.interrupted
        }
        if transcriptions.consumeCancelledReplacement(for: episodeID) {
            return PassFailure(FailureMessage.transcriptCancelled)
        }
        return PassFailure(transcriptions.lastErrorMessage(for: episodeID) ?? FailureMessage.transcriptFailed)
    }

    /// Whether the stopped pass should hold its item for the environmental
    /// auto-resume. An interrupted replacement restored the prior transcript
    /// onto the record, so only the store's note can say; the pass reads it
    /// once.
    private func consumeEnvironmentalInterruption(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore
    ) -> Bool {
        if let interruption = transcriptions.consumeInterruptedReplacement(for: episodeID) {
            return interruption.isEnvironmental
        }
        return transcriptions.hasEnvironmentalInterruptionPending(for: episodeID)
    }

    /// The trusted form of attachment, through the pass's own stores.
    private func isAnalysisAttached(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        downloads: DownloadStore
    ) -> Bool {
        EpisodeAdAnalysisAttachment.resolve(
            transcriptSourceSHA256: transcriptions.record(for: episodeID)?.sourceFileSHA256 ?? "",
            trustedDownloadSHA256: downloads.completedSourceIdentity(for: episodeID)?.sha256
        ) == .attached
    }

    private func presentationRequiresWhisperModel(
        for engine: AdFreePassTranscriptionEngine,
        appleSpeechAssets: AppleSpeechAssetStore
    ) -> Bool {
        switch engine {
        case .productDefault:
            !appleSpeechAssets.isTranscriberAvailable
        case .selectedWhisperModel, .whisperTiny:
            true
        case .appleSpeech:
            false
        }
    }

    private func transcriptionFailureMessage(_ state: EpisodeTranscriptionJobState) -> String {
        switch state {
        case .failed(let record):
            record.errorMessage ?? FailureMessage.transcriptFailed
        case .cancelled:
            FailureMessage.transcriptCancelled
        default:
            FailureMessage.transcriptFailed
        }
    }

    private func failureMessage(for episodeID: String) -> String? {
        failureMessagesByEpisodeID[episodeID]
    }

    private func recordFailure(_ message: String, episodeID: String) {
        failureMessagesByEpisodeID[episodeID] = message
        lastFailureEpisodeID = episodeID
        lastFailureMessage = message
    }

    private func clearFailure(episodeID: String) {
        failureMessagesByEpisodeID[episodeID] = nil
        if lastFailureEpisodeID == episodeID {
            lastFailureEpisodeID = nil
            lastFailureMessage = nil
        }
    }

    private func setStage(_ stage: EpisodeAdFreePassStage) {
        guard lastPublishedStage != stage else {
            return
        }

        let isFirstConcreteStage = lastPublishedStage == nil
        lastPublishedStage = stage
        currentStage = stage
        if isFirstConcreteStage {
            SoundLabResponsivenessDiagnostics.mark(
                "coordinator-first-concrete-stage",
                episodeID: activeEpisodeID
            )
        }
        let context = currentQueueContext
        _ = uiProgressMapper.update(for: stage, queueContext: context)
        onStageChange?(stage, context)
    }

    private enum PassStop: Error {
        case awaitingModelConsent
        case interrupted
        case keyRequired(AnalysisKeyRequiredReason)
    }

    private struct PassFailure: LocalizedError {
        var message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

}
