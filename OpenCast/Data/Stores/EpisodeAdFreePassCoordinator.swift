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
    // Observed (not ignored) so pending-queue mutations — enqueue, drain,
    // removePendingItem — invalidate views reading queueStatus/queueSnapshot.
    private var entries: [QueueEntry] = []
    @ObservationIgnored private var lastPublishedStage: EpisodeAdFreePassStage?
    @ObservationIgnored private var activeTranscriptionEngine: AdFreePassTranscriptionEngine = .productDefault
    @ObservationIgnored private var activeTranscriptionModelIdentity: EpisodeTranscriptionModelIdentity?
    @ObservationIgnored private var stickyComputeProfile: OpenCastTranscriptionComputeProfile?
    @ObservationIgnored private var pausedForEnvironmentalInterrupt = false
    @ObservationIgnored private var lastInterruptedEpisodeID: String?
    @ObservationIgnored private var hasProbedCapThisForegroundSession = false
    @ObservationIgnored private let launchPreparationGate: @Sendable () async -> Void
    @ObservationIgnored var onStageChange: (@MainActor (EpisodeAdFreePassStage, AdFreePassQueueContext) -> Void)?
    @ObservationIgnored var onQueueTerminal: (@MainActor (AdFreePassQueueTerminalOutcome) -> Void)?
    @ObservationIgnored var isBackgroundProtected: @MainActor () -> Bool = { false }

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

    var queueSnapshot: AdFreePassQueueSnapshot {
        AdFreePassQueueSnapshot(
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
        if activeItem?.episodeID == episodeID {
            return .running
        }

        if let index = entries.firstIndex(where: { $0.item.episodeID == episodeID }) {
            if queueState == .capDeferred, index == 0 {
                return .capDeferred
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
            }
        }

        return .notQueued
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

        // Cloud stages live entirely in the coordinator (no local store
        // reflects them), so the active cloud item presents from its stage.
        if activeEpisodeID == episodeID, let currentStage {
            switch currentStage {
            case .cloudQueued:
                return .cloudQueued
            case .cloudTranscribing(let progress):
                return .cloudTranscribing(progress)
            case .cloudDetectingAds:
                return .cloudDetectingAds
            case .cloudUnavailable(let message):
                return .cloudUnavailable(message)
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
            return isCurrent ? .completed(zoneCount: currentZoneCount) : .outdated
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
        prepareBackgroundSession: @escaping @MainActor () -> Void = {},
        refreshSkipZones: @escaping @MainActor () -> Int
    ) {
        let episodeID = episode.episodeID

        guard activeItem?.episodeID != episodeID else {
            return
        }

        if entries.contains(where: { $0.item.episodeID == episodeID }) {
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
            mode: mode
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
            launchPreparation: launchPreparation
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
        case .running, .pausedInterrupted, .awaitingModelConsent, .capDeferred:
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
        refreshSkipZones: @escaping @MainActor (EpisodeListItemSnapshot) -> Int
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

            let mode = AdDetectionMode(rawValue: record.modeRawValue) ?? .onDevice
            let item = AdFreePassQueueItem(
                episode: episode,
                origin: origin,
                enqueuedAt: record.enqueuedAt,
                sequence: record.sequence,
                mode: mode
            )
            // Restored items drain foreground-opportunistically; background
            // continuation always requires a fresh explicit tap (decision 5).
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
                    refreshSkipZones: { refreshSkipZones(episode) },
                    remoteRunner: remoteRunner,
                    remoteJobStore: remoteJobStore,
                    remotePurchases: remotePurchases
                ),
                launchPreparation: nil
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

    func resumeQueueForEnvironmentalAutoResume() {
        guard isQueuePausedForEnvironmentalInterrupt else {
            return
        }

        pausedForEnvironmentalInterrupt = false
        if let prepareBackgroundSession = entries.first?.deps.prepareBackgroundSession {
            scheduleResumeLaunchPreparation(
                prepareBackgroundSession: prepareBackgroundSession
            )
        }
        startDrain()
    }

    func resumePausedQueue() {
        switch queueState {
        case .pausedInterrupted, .awaitingModelConsent, .capDeferred:
            pausedForEnvironmentalInterrupt = false
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
        hasProbedCapThisForegroundSession = false
    }

    func probeCapDeferredQueueIfAllowed(trigger: AdFreePassCapDeferralPolicy.Trigger) {
        let policy = AdFreePassCapDeferralPolicy(
            queueState: queueState,
            hasProbedThisForegroundSession: hasProbedCapThisForegroundSession,
            trigger: trigger
        )
        guard policy.shouldProbe else {
            return
        }

        hasProbedCapThisForegroundSession = true
        AdFreePassBackgroundRunLog.record("cap probe trigger=\(trigger)")
        startDrain()
    }

    func republishCurrentStage() {
        guard let lastPublishedStage else {
            return
        }
        onStageChange?(lastPublishedStage, currentQueueContext)
    }

    func reset() {
        cancellationSource.cancel()
        passTask?.cancel()
        passTask = nil
        cancellationSource.clearTask()
        for entry in entries {
            entry.launchPreparation?.cancel()
        }
        entries = []
        activeItem = nil
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
        lastInterruptedEpisodeID = nil
    }

    func cancelActivePass() {
        cancellationSource.cancel()
    }

    func removePendingItem(episodeID: String, modelContext: ModelContext) {
        guard activeItem?.episodeID != episodeID else {
            return
        }

        let countBefore = entries.count
        for entry in entries where entry.item.episodeID == episodeID {
            entry.launchPreparation?.cancel()
        }
        entries.removeAll { $0.item.episodeID == episodeID }
        guard entries.count != countBefore else {
            return
        }

        removePersistedItem(episodeID: episodeID, modelContext: modelContext)
        if pendingModelConsentEpisodeID == episodeID {
            pendingModelConsentEpisodeID = nil
            pendingModelConsentByteCount = nil
        }
        if entries.isEmpty, passTask == nil {
            queueState = .idle
        }
        AdFreePassBackgroundRunLog.record(
            "queue removed pending episodeID=\(episodeID) pending=\(entries.count) state=\(queueState)"
        )
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
        let refreshSkipZones: @MainActor () -> Int
        // Cloud detect passes only; on-device items never touch these.
        var remoteRunner: RemoteTranscriptionJobRunner?
        var remoteJobStore: RemoteTranscriptionJobStore?
        var remotePurchases: RemoteTranscriptionPurchaseStore?
    }

    private struct QueueEntry {
        let item: AdFreePassQueueItem
        let deps: PassDependencies
        var launchPreparation: Task<LaunchPreparationOutcome, Never>?
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
        case capDeferred
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
        case .capDeferred:
            // A manual tap on the deferred episode is always allowed to probe.
            hasProbedCapThisForegroundSession = true
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

        if item.origin == .auto,
           await currentCompletedAnalysisVerdict(
               for: item.episodeID,
               transcriptions: dependencies.transcriptions,
               adAnalyses: dependencies.adAnalyses
           ) {
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

        queueState = .running
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await drainQueue()
        }
        passTask = task
        cancellationSource.start(task)
    }

    private func drainQueue() async {
        // Whisper-perf E1: retain the loaded runtime across items within
        // this drain only (items 2..n skip the ~4.4 s model load when the
        // model + compute profile match). Ended on every drain exit path;
        // failures, profile changes, and memory warnings drop it earlier.
        let retentionStore = entries.first?.deps.transcriptions
        retentionStore?.beginModelRetentionDrain()
        defer {
            if let retentionStore {
                Task { await retentionStore.endModelRetentionDrain() }
            }
        }

        while !entries.isEmpty {
            let pendingEntry = entries[0]
            let launchPreparation = await pendingEntry.launchPreparation?.value ?? .ready
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
                    kind: .failed(message: message)
                ))
                continue
            }

            let entry = entries.removeFirst()
            activeItem = entry.item
            lastPublishedStage = nil
            activeTranscriptionEngine = entry.deps.transcriptionEngine
            activeTranscriptionModelIdentity = nil
            AdFreePassBackgroundRunLog.record(
                "queue item starting episodeID=\(entry.item.episodeID) origin=\(entry.item.origin.rawValue) finished=\(finishedItemCount) total=\(drainTotalItemCount)"
            )
            AdFreePassBackgroundRunLog.record(
                "transcription engine requested=\(entry.deps.transcriptionEngine.logDescription)"
            )

            let outcome = await runPass(entry)

            if isBackgroundProtected(),
               entry.deps.transcriptions.lastEnvironmentalComputeFallbackEpisodeID == entry.item.episodeID {
                stickyComputeProfile = .cpuOnly
            }
            activeItem = nil
            activeTranscriptionEngine = .productDefault
            activeTranscriptionModelIdentity = nil

            switch outcome {
            case .completed(let zoneCount):
                drainCompletedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .completed(zoneCount: zoneCount)
                ))
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            case .failed(let message):
                drainFailedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .failed(message: message)
                ))
                removePersistedItem(episodeID: entry.item.episodeID, modelContext: entry.deps.modelContext)
            case .cloudUnavailable(let message):
                drainFailedCount += 1
                drainOutcomes.append(AdFreePassQueueItemOutcome(
                    episodeID: entry.item.episodeID,
                    episodeTitle: entry.item.episode.title,
                    artworkURL: entry.item.episode.artworkURL,
                    kind: .cloudUnavailable(message: message)
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
            case .capDeferred:
                // The head item is retained (and stays persisted) so the
                // deferral survives relaunch; this failed call was the
                // foreground session's one probe.
                entries.insert(entry, at: 0)
                hasProbedCapThisForegroundSession = true
                endDrain(state: .capDeferred, terminal: .capDeferred)
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

    private func runPass(_ entry: QueueEntry) async -> PassOutcome {
        if entry.item.mode == .cloud {
            return await runCloudPass(entry)
        }
        let episode = entry.item.episode
        let deps = entry.deps

        do {
            let downloadRecord = try await completedDownload(
                for: episode,
                downloads: deps.downloads,
                modelContext: deps.modelContext
            )

            // Decision 3: a completed transcript counts as done for the
            // default path regardless of engine — skip engine resolution and
            // resource setup entirely.
            let transcriptDocument: EpisodeTranscriptDocument
            if !deps.transcriptionEngine.isExplicitOverride,
               let reusableDocument = await reusableCompletedTranscriptDocument(
                   for: episode.episodeID,
                   transcriptions: deps.transcriptions
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
                    downloadRecord: downloadRecord,
                    downloads: deps.downloads,
                    transcriptionModels: deps.transcriptionModels,
                    transcriptions: deps.transcriptions,
                    transcriptionPlan: transcriptionPlan,
                    modelContext: deps.modelContext
                )
            }
            try await completedAnalysis(
                for: transcriptDocument,
                transcriptions: deps.transcriptions,
                adAnalyses: deps.adAnalyses,
                modelContext: deps.modelContext
            )
            let zoneCount = deps.refreshSkipZones()
            clearFailure(episodeID: episode.episodeID)
            setStage(.completed(zoneCount: zoneCount))
            return .completed(zoneCount: zoneCount)
        } catch PassStop.awaitingModelConsent {
            return .awaitingConsent
        } catch PassStop.capDeferred {
            return .capDeferred
        } catch PassStop.interrupted {
            setStage(.interrupted)
            return .interrupted(
                environmental: deps.transcriptions.hasEnvironmentalInterruptionPending(for: episode.episodeID)
            )
        } catch is CancellationError {
            setStage(.interrupted)
            return .interrupted(
                environmental: deps.transcriptions.hasEnvironmentalInterruptionPending(for: episode.episodeID)
            )
        } catch {
            recordFailure(error.localizedDescription, episodeID: episode.episodeID)
            setStage(.failed(message: error.localizedDescription))
            return .failed(message: error.localizedDescription)
        }
    }

    /// One cloud detect item: transcript reuse first (free), then a
    /// viability precheck (never a silent mode switch), then one server job
    /// with chained ad detection. The transcript always imports when the job
    /// delivers; a failed/invalid ad block falls back to the on-device
    /// analysis path over that imported transcript automatically.
    private func runCloudPass(_ entry: QueueEntry) async -> PassOutcome {
        let episode = entry.item.episode
        let deps = entry.deps

        do {
            // Decision 5: a current completed local transcript never buys a
            // cloud job — the analysis-only device path is free.
            if let reusableDocument = await reusableCompletedTranscriptDocument(
                for: episode.episodeID,
                transcriptions: deps.transcriptions
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
            if jobStore.hasActiveRequest, jobStore.activeEpisodeID == episode.episodeID {
                // A plain Transcribe Remotely job already owns this episode;
                // it will deliver the transcript the free path can use.
                return cloudUnavailableOutcome(
                    "A remote transcription of this episode is already running.",
                    episodeID: episode.episodeID
                )
            }

            let outcome = try await runner.run(
                episode: episode,
                enclosureURL: audioURL,
                purpose: .adDetection,
                adAnalysis: RemoteTranscriptionJobRunner.AdAnalysisContext(
                    podcastID: episode.podcastID,
                    episodeTitle: episode.title,
                    podcastTitle: episode.podcastTitle
                ),
                modelContext: deps.modelContext,
                onEvent: { [weak self] event in
                    self?.applyCloudEvent(event)
                }
            )

            if case .completed(let success) = outcome.adAnalysis {
                do {
                    let analysisDocument = try EpisodeRemoteAdAnalysisMapper.document(
                        from: success,
                        transcript: outcome.document,
                        requestID: outcome.jobID
                    )
                    try deps.adAnalyses.importCompletedAnalysis(
                        analysisDocument,
                        modelContext: deps.modelContext
                    )
                    let zoneCount = deps.refreshSkipZones()
                    clearFailure(episodeID: episode.episodeID)
                    setStage(.completed(zoneCount: zoneCount))
                    return .completed(zoneCount: zoneCount)
                } catch {
                    AdFreePassBackgroundRunLog.record(
                        "cloud analysis import rejected episodeID=\(episode.episodeID); falling back to device analysis"
                    )
                }
            }
            // Failure marker, missing block, or an import the mapper refused:
            // the transcript is durably imported, so the existing on-device
            // analysis path finishes the pass automatically.
            return try await finishCloudPassWithAnalysis(
                transcript: outcome.document,
                entry: entry
            )
        } catch PassStop.capDeferred {
            return .capDeferred
        } catch PassStop.awaitingModelConsent {
            return .awaitingConsent
        } catch PassStop.interrupted {
            setStage(.interrupted)
            return .interrupted(environmental: false)
        } catch is CancellationError {
            // The runner already fired the server cancel; the charge stands
            // once the job settled (documented server behavior).
            deps.remoteJobStore?.clearReference(for: episode.episodeID, purpose: .adDetection)
            setStage(.interrupted)
            return .interrupted(environmental: false)
        } catch let error as RemoteTranscriptionJobRunError {
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

    /// Shared tail of the cloud pass: run (or reuse) the on-device analysis
    /// over a completed transcript, with cap-deferral semantics intact.
    private func finishCloudPassWithAnalysis(
        transcript: EpisodeTranscriptDocument,
        entry: QueueEntry
    ) async throws -> PassOutcome {
        try await completedAnalysis(
            for: transcript,
            transcriptions: entry.deps.transcriptions,
            adAnalyses: entry.deps.adAnalyses,
            modelContext: entry.deps.modelContext
        )
        let zoneCount = entry.deps.refreshSkipZones()
        clearFailure(episodeID: entry.item.episodeID)
        setStage(.completed(zoneCount: zoneCount))
        return .completed(zoneCount: zoneCount)
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
        case .verifying, .queuedRemotely, .waitingForCredits, .uploadingExactCopy:
            setStage(.cloudQueued)
        case .processing(let progress) where progress.stage == .finalizing:
            // Finalization follows the ad phase on detect jobs; falling back
            // to "Transcribing" copy here would read as a regression.
            setStage(.cloudDetectingAds)
        case .processing(let progress):
            setStage(.cloudTranscribing(progress))
        case .detectingAds, .saving:
            setStage(.cloudDetectingAds)
        }
    }

    /// Failures where "Detect on this device instead" is the honest recovery
    /// (credits, capacity, kill switch, unreachable service) — never a
    /// silent mode switch, always the explicit one-tap fallback.
    private static func isCloudUnavailableRunError(_ error: RemoteTranscriptionJobRunError) -> Bool {
        switch error {
        case .serviceUnavailable:
            true
        case .serverRejected(let code):
            code == .featureDisabled
                || code == .insufficientCredits
                || code == .rateLimited
        case .downloadFailed, .remoteCancelled, .mismatchLocalFallback, .resultInvalid:
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

        switch queueState {
        case .running:
            return .queued(ahead: index + (activeItem != nil ? 1 : 0))
        case .capDeferred where index == 0:
            return .capDeferred
        case .pausedInterrupted, .awaitingModelConsent, .capDeferred, .idle:
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

    private func reusableCompletedTranscriptDocument(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore
    ) async -> EpisodeTranscriptDocument? {
        guard let record = transcriptions.record(for: episodeID),
              record.state == .completed
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
        return document
    }

    private func completedDownload(
        for episode: EpisodeListItemSnapshot,
        downloads: DownloadStore,
        modelContext: ModelContext
    ) async throws -> EpisodeDownloadRecord {
        setStage(.downloadingEpisode)

        do {
            return try await downloads.ensureCompletedDownload(
                for: episode,
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
            // (decision 1's fallback target) and run the existing
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
        downloadRecord: EpisodeDownloadRecord,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptionPlan: EpisodeTranscriptionPlan,
        modelContext: ModelContext
    ) async throws -> EpisodeTranscriptDocument {
        var didStartTranscription = false

        while true {
            try Task.checkCancellation()

            let modelChangeSequence = transcriptionModels.changeSequence
            let transcriptionChangeSequence = transcriptions.changeSequence
            let state = transcriptions.jobState(
                for: episode.episodeID,
                downloadRecord: downloadRecord,
                modelState: transcriptionModels.state,
                modelIdentity: transcriptionPlan.isEngineStrict ? transcriptionPlan.modelIdentity : nil,
                requiresInstalledWhisperModel: transcriptionPlan.requiresInstalledWhisperModel
            )
            switch state {
            case .completed:
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
                return document
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
                    modelContext: modelContext
                )
            case .ready, .failed, .cancelled:
                try await startTranscriptionOrThrowOnSecondAttempt(
                    secondPassError: PassFailure(transcriptionFailureMessage(state)),
                    didStartTranscription: &didStartTranscription,
                    episode: episode,
                    downloadRecord: downloadRecord,
                    downloads: downloads,
                    transcriptionModels: transcriptionModels,
                    transcriptions: transcriptions,
                    transcriptionPlan: transcriptionPlan,
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
        modelContext: ModelContext
    ) async throws {
        var didStartAnalysis = false

        while true {
            try Task.checkCancellation()

            let analysisChangeSequence = adAnalyses.changeSequence
            if adAnalyses.isRunning(for: transcriptDocument.episodeID) {
                setStage(.analyzing)
            } else if let record = adAnalyses.record(for: transcriptDocument.episodeID) {
                switch record.state {
                case .queued, .running:
                    setStage(.analyzing)
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
                        modelContext: modelContext
                    )
                case .failed:
                    guard !didStartAnalysis else {
                        if record.failureKind == .capExceeded {
                            throw PassStop.capDeferred
                        }
                        throw PassFailure(
                            record.errorMessage
                                ?? adAnalyses.lastErrorMessage(for: transcriptDocument.episodeID)
                                ?? FailureMessage.analysisFailed
                        )
                    }
                    try startAnalysisOrThrowOnSecondAttempt(
                        didStartAnalysis: &didStartAnalysis,
                        transcriptDocument: transcriptDocument,
                        transcriptions: transcriptions,
                        adAnalyses: adAnalyses,
                        modelContext: modelContext
                    )
                }
            } else {
                if let unavailableMessage = adAnalyses.analysisStartUnavailableMessage {
                    throw PassFailure(unavailableMessage)
                }
                guard !didStartAnalysis else {
                    throw PassFailure(
                        adAnalyses.lastErrorMessage(for: transcriptDocument.episodeID)
                            ?? FailureMessage.analysisFailed
                    )
                }
                try startAnalysisOrThrowOnSecondAttempt(
                    didStartAnalysis: &didStartAnalysis,
                    transcriptDocument: transcriptDocument,
                    transcriptions: transcriptions,
                    adAnalyses: adAnalyses,
                    modelContext: modelContext
                )
            }

            try await adAnalyses.waitForChange(after: analysisChangeSequence)
        }
    }

    private func startAnalysisOrThrowOnSecondAttempt(
        didStartAnalysis: inout Bool,
        transcriptDocument: EpisodeTranscriptDocument,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        modelContext: ModelContext
    ) throws {
        guard !didStartAnalysis else {
            if adAnalyses.record(for: transcriptDocument.episodeID)?.failureKind == .capExceeded {
                throw PassStop.capDeferred
            }
            throw PassFailure(
                adAnalyses.lastErrorMessage(for: transcriptDocument.episodeID)
                    ?? FailureMessage.analysisFailed
            )
        }

        adAnalyses.startAnalysis(
            transcript: transcriptDocument,
            transcriptState: transcriptions.record(for: transcriptDocument.episodeID)?.state,
            modelContext: modelContext
        )
        didStartAnalysis = true
        setStage(.analyzing)
    }

    private func installModelIfConsentedOrStop(
        _ transcriptionModels: TranscriptionModelStore
    ) async throws -> Bool {
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
        secondPassError: any Error,
        didStartTranscription: inout Bool,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptionPlan: EpisodeTranscriptionPlan,
        modelContext: ModelContext
    ) async throws {
        guard !didStartTranscription else {
            throw secondPassError
        }

        try await startTranscription(
            episode,
            downloadRecord: downloadRecord,
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            transcriptions: transcriptions,
            transcriptionPlan: transcriptionPlan,
            modelContext: modelContext
        )
        didStartTranscription = true
    }

    private func startTranscription(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptionPlan: EpisodeTranscriptionPlan,
        modelContext: ModelContext
    ) async throws {
        guard let localFileURL = downloads.localFileURL(for: downloadRecord),
              downloads.downloadedFileExists(for: downloadRecord)
        else {
            try? downloads.markDownloadedFileMissing(downloadRecord, modelContext: modelContext)
            throw EpisodeTranscriptionError.missingDownloadedFile
        }

        // Decision 20: after a classified cpuOnly fallback inside a protected
        // drain, subsequent whisper items skip the doomed default attempt.
        let initialComputeProfile: OpenCastTranscriptionComputeProfile =
            transcriptionPlan.runEngine == .whisper
                ? (stickyComputeProfile ?? .backgroundSafe)
                : .backgroundSafe

        transcriptions.startTranscription(
            episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            engine: transcriptionPlan.runEngine,
            modelIdentity: transcriptionPlan.modelIdentity,
            languageCode: transcriptionPlan.languageCode,
            runLanguageCode: transcriptionPlan.runLanguageCode,
            initialComputeProfile: initialComputeProfile,
            modelContext: modelContext
        )
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
        case capDeferred
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
