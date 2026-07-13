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
    @ObservationIgnored var onStageChange: (@MainActor (EpisodeAdFreePassStage, AdFreePassQueueContext) -> Void)?
    @ObservationIgnored var onQueueTerminal: (@MainActor (AdFreePassQueueTerminalOutcome) -> Void)?
    @ObservationIgnored var isBackgroundProtected: @MainActor () -> Bool = { false }

    init(cancellationSource: AdFreePassCancellationSource = AdFreePassCancellationSource()) {
        self.cancellationSource = cancellationSource
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
        case .completed:
            break
        case .unavailable, .downloadRequired, .modelRequired, .modelBusy, .ready:
            if let lastFailure = failureMessage(for: episodeID) {
                return .failed(lastFailure)
            }
            return .idle
        }

        guard let transcriptDocument = transcriptions.document(for: episodeID) else {
            if let lastFailure = failureMessage(for: episodeID) {
                return .failed(lastFailure)
            }
            return .idle
        }

        switch adAnalyses.jobState(
            for: transcriptDocument,
            transcriptState: transcriptions.record(for: episodeID)?.state
        ) {
        case .running:
            return .analyzing
        case .completed(_, let isStale):
            return isStale ? .outdated : .completed(zoneCount: currentZoneCount)
        case .failed(let record, let isStale):
            if isStale {
                return .outdated
            }
            return .failed(record.errorMessage ?? "Promo/ad analysis failed.")
        case .unavailable(let message):
            return .unavailable(message)
        case .ready:
            if let lastFailure = failureMessage(for: episodeID) {
                return .failed(lastFailure)
            }
            return .idle
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

        if origin == .auto,
           hasCurrentCompletedAnalysis(
               for: episodeID,
               transcriptions: transcriptions,
               adAnalyses: adAnalyses
           ) {
            return
        }

        beginDrainSessionIfNeeded()

        let insertsAtFront = origin == .auto
            || (queueState == .pausedInterrupted && lastInterruptedEpisodeID == episodeID)
        let item = AdFreePassQueueItem(
            episode: episode,
            origin: origin,
            enqueuedAt: .now,
            sequence: nextSequence(front: insertsAtFront)
        )
        let entry = QueueEntry(
            item: item,
            deps: PassDependencies(
                downloads: downloads,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses,
                modelContext: modelContext,
                transcriptionEngine: transcriptionEngine,
                podcastLanguageCode: podcastLanguageCode,
                prepareBackgroundSession: prepareBackgroundSession,
                refreshSkipZones: refreshSkipZones
            )
        )
        if insertsAtFront {
            entries.insert(entry, at: 0)
        } else {
            entries.append(entry)
        }
        persistItem(item, modelContext: modelContext)
        clearFailure(episodeID: episodeID)
        prepareBackgroundSession()
        AdFreePassBackgroundRunLog.record(
            "queue enqueued episodeID=\(episodeID) origin=\(origin.rawValue) front=\(insertsAtFront) pending=\(entries.count) state=\(queueState)"
        )

        switch queueState {
        case .idle:
            startDrain()
        case .pausedInterrupted where lastInterruptedEpisodeID == episodeID:
            startDrain()
        case .running, .pausedInterrupted, .awaitingModelConsent, .capDeferred:
            break
        }
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
            guard !alreadyQueued,
                  let origin = AdFreePassQueueOrigin(rawValue: record.originRawValue),
                  let episode = resolveEpisode(record.episodeID)
            else {
                modelContext.delete(record)
                didDropRecords = true
                continue
            }

            let item = AdFreePassQueueItem(
                episode: episode,
                origin: origin,
                enqueuedAt: record.enqueuedAt,
                sequence: record.sequence
            )
            // Restored items drain foreground-opportunistically; background
            // continuation always requires a fresh explicit tap (decision 5).
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
                    refreshSkipZones: { refreshSkipZones(episode) }
                )
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
        entries.first?.deps.prepareBackgroundSession()
        startDrain()
    }

    func resumePausedQueue() {
        switch queueState {
        case .pausedInterrupted, .awaitingModelConsent, .capDeferred:
            pausedForEnvironmentalInterrupt = false
            entries.first?.deps.prepareBackgroundSession()
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
    }

    private struct QueueEntry {
        let item: AdFreePassQueueItem
        let deps: PassDependencies
    }

    private enum PassOutcome {
        case completed(zoneCount: Int)
        case failed(message: String)
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
        prepareBackgroundSession: @MainActor () -> Void
    ) {
        guard entries.first?.item.episodeID == episodeID else {
            return
        }

        switch queueState {
        case .awaitingModelConsent, .pausedInterrupted:
            pausedForEnvironmentalInterrupt = false
            prepareBackgroundSession()
            startDrain()
        case .capDeferred:
            // A manual tap on the deferred episode is always allowed to probe.
            hasProbedCapThisForegroundSession = true
            prepareBackgroundSession()
            startDrain()
        case .idle, .running:
            break
        }
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
               let reusableDocument = reusableCompletedTranscriptDocument(
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

    func hasCurrentCompletedAnalysis(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) -> Bool {
        guard adAnalyses.record(for: episodeID)?.state == .completed,
              let transcriptRecord = transcriptions.record(for: episodeID),
              transcriptRecord.state == .completed,
              let transcriptDocument = transcriptions.document(for: episodeID),
              let analysisDocument = adAnalyses.document(for: episodeID)
        else {
            return false
        }

        return adAnalyses.isCurrentAnalysisDocument(analysisDocument, for: transcriptDocument)
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

    private func persistItem(_ item: AdFreePassQueueItem, modelContext: ModelContext) {
        modelContext.insert(AdFreePassQueueItemRecord(
            episodeID: item.episodeID,
            podcastID: item.episode.podcastID,
            originRawValue: item.origin.rawValue,
            enqueuedAt: item.enqueuedAt,
            sequence: item.sequence
        ))
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

    private func reusableCompletedTranscriptDocument(
        for episodeID: String,
        transcriptions: EpisodeTranscriptionStore
    ) -> EpisodeTranscriptDocument? {
        guard let record = transcriptions.record(for: episodeID),
              record.state == .completed
        else {
            return nil
        }
        return transcriptions.document(for: episodeID)
    }

    private func completedDownload(
        for episode: EpisodeListItemSnapshot,
        downloads: DownloadStore,
        modelContext: ModelContext
    ) async throws -> EpisodeDownloadRecord {
        var didStartDownload = false
        setStage(.downloadingEpisode)

        while true {
            try Task.checkCancellation()

            if let record = downloads.record(for: episode.episodeID) {
                switch record.state {
                case .completed:
                    guard downloads.downloadedFileExists(for: record) else {
                        try? downloads.markDownloadedFileMissing(record, modelContext: modelContext)
                        throw EpisodeDownloadError.missingDownloadedFile
                    }
                    return record
                case .downloading:
                    try await downloads.waitForDownload(episodeID: episode.episodeID)
                case .paused, .failed, .missing:
                    guard !didStartDownload else {
                        let message = record.state == .paused
                            ? "Download paused."
                            : record.errorMessage ?? EpisodeDownloadError.missingDownloadedFile.localizedDescription
                        throw PassFailure(message)
                    }
                    downloads.startDownload(for: episode, modelContext: modelContext)
                    didStartDownload = true
                    try await downloads.waitForDownload(episodeID: episode.episodeID)
                }
            } else {
                downloads.startDownload(for: episode, modelContext: modelContext)
                didStartDownload = true
                try await downloads.waitForDownload(episodeID: episode.episodeID)
            }
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
                guard let document = transcriptions.document(for: episode.episodeID) else {
                    throw EpisodeTranscriptionError.transcriptDocumentMissing
                }
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
            switch adAnalyses.jobState(
                for: transcriptDocument,
                transcriptState: transcriptions.record(for: transcriptDocument.episodeID)?.state
            ) {
            case .completed(_, let isStale) where !isStale:
                return
            case .running:
                setStage(.analyzing)
                break
            case .ready, .completed:
                guard !didStartAnalysis else {
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
            case .failed(let record, _):
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
                adAnalyses.startAnalysis(
                    transcript: transcriptDocument,
                    transcriptState: transcriptions.record(for: transcriptDocument.episodeID)?.state,
                    modelContext: modelContext
                )
                didStartAnalysis = true
                setStage(.analyzing)
            case .unavailable(let message):
                throw PassFailure(message)
            }

            try await adAnalyses.waitForChange(after: analysisChangeSequence)
        }
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

        lastPublishedStage = stage
        currentStage = stage
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
