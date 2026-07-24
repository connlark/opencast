import Foundation
import Observation
import OSLog

@Observable
final class EpisodeAdFreePassBackgroundSession {
    static let identifier = "com.connor.opencast.ad-free-pass"

    private enum State: Equatable {
        case idle
        case submitted
        case running
        case foregroundOnly
    }

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "AdFreePassBackground")
    private static let title = "Skip Promos & Ads"
    private static let consentSubtitle = "Needs your OK to download the speech model - open OpenCast."
    private static let capDeferredSubtitle = "Daily detection limit reached — continues tomorrow"
    private static let creepInterval: Duration = .seconds(2)

    @ObservationIgnored private let scheduler: any AdFreePassContinuedTaskScheduling
    @ObservationIgnored private let forceForegroundOnly: @MainActor () -> Bool
    private var state: State = .idle
    private var hasRegisteredLaunchHandler = false
    private var handle: (any AdFreePassContinuedTaskHandle)?
    private var mapper = AdFreePassQueueProgressMapper()
    private var stage: EpisodeAdFreePassStage = .idle
    private var queueContext = AdFreePassQueueContext()
    private var stageBeganAt = Date.now
    @ObservationIgnored private var creepTask: Task<Void, Never>?
    private var terminalOutcomeNotedBeforeLaunch: AdFreePassQueueTerminalOutcome?
    private var hasCompletedTask = false
    private var lastLoggedStageSummary: String?
    private var lastLoggedCompletedUnits: Int64?
    private var lastLoggedEnvironmentStageKey: String?
    private var lastTranscribingProgressLoggedAt: Date?
    private var lastTranscribingCompletedDuration: TimeInterval?
    private var runSequence = 0

    @ObservationIgnored private var cancellationSource = AdFreePassCancellationSource()
    @ObservationIgnored private var completionGate = AdFreePassOnceGate()
    @ObservationIgnored private var expirationGate = AdFreePassOnceGate()
    @ObservationIgnored var onExpiration: (() -> Void)?

    init(
        scheduler: any AdFreePassContinuedTaskScheduling = BGTaskSchedulerAdFreePassScheduler(),
        forceForegroundOnly: @escaping @MainActor () -> Bool = EpisodeAdFreePassBackgroundSession.environmentForcesForegroundOnly
    ) {
        self.scheduler = scheduler
        self.forceForegroundOnly = forceForegroundOnly
    }

    deinit {
        creepTask?.cancel()
    }

    var isProtectingBackgroundExecution: Bool {
        handle != nil && state == .running
    }

    /// True while a run is submitted or live. Manual enqueues consult this so
    /// appending to an armed queue never resubmits (one task per drain).
    var isArmed: Bool {
        state == .submitted || state == .running
    }

    func arm(
        episodeTitle: String,
        cancellationSource: AdFreePassCancellationSource = AdFreePassCancellationSource()
    ) {
        guard canStartNewRun else {
            assertionFailure("A background ad-free pass session is already active.")
            return
        }

        if state == .submitted && handle == nil {
            cancelSubmittedRequest(reason: "rearm")
        }

        resetRunState(keepsForegroundOnly: false)
        self.cancellationSource = cancellationSource
        runSequence += 1
        let subtitle = Self.truncatedTitleText(episodeTitle)
        AdFreePassBackgroundRunLog.record("arm episodeTitle=\(episodeTitle) subtitle=\(subtitle)")
        AdFreePassBackgroundEnvironmentSnapshot.record(reason: "arm")
        guard !forceForegroundOnly() else {
            state = .foregroundOnly
            AdFreePassBackgroundRunLog.record("arm foregroundOnly reason=debugForced")
            return
        }
        guard registerLaunchHandlerIfNeeded() else {
            state = .foregroundOnly
            AdFreePassBackgroundRunLog.record("arm foregroundOnly reason=registrationFailed")
            return
        }

        do {
            cancelSubmittedRequest(reason: "pre-submit")
            try submitRequest(subtitle: subtitle, requiresGPU: scheduler.supportsGPUResources)
            state = .submitted
            Self.logger.log("submitted continued processing task")
        } catch {
            state = .foregroundOnly
            Self.logger.error("continued processing submission failed: \(error.localizedDescription, privacy: .public)")
            AdFreePassBackgroundRunLog.record("submit failed error=\(error.localizedDescription)")
        }
    }

    /// Decision 16 retry ladder: a GPU-required submission retries once
    /// without GPU before the caller degrades to foreground-only.
    private func submitRequest(subtitle: String, requiresGPU: Bool) throws {
        do {
            try scheduler.submit(
                identifier: Self.identifier,
                title: Self.title,
                subtitle: subtitle,
                requiresGPU: requiresGPU
            )
            AdFreePassBackgroundRunLog.record("submit success identifier=\(Self.identifier) gpu=\(requiresGPU)")
        } catch {
            guard requiresGPU else {
                throw error
            }

            Self.logger.error("continued processing GPU submission failed, retrying without GPU: \(error.localizedDescription, privacy: .public)")
            AdFreePassBackgroundRunLog.record("submit gpu failed error=\(error.localizedDescription) retryingWithoutGPU=true")
            try scheduler.submit(
                identifier: Self.identifier,
                title: Self.title,
                subtitle: subtitle,
                requiresGPU: false
            )
            AdFreePassBackgroundRunLog.record("submit success identifier=\(Self.identifier) gpu=false afterGPURetry=true")
        }
    }

    func noteStage(
        _ newStage: EpisodeAdFreePassStage,
        queueContext: AdFreePassQueueContext = AdFreePassQueueContext()
    ) {
        guard newStage != stage || queueContext != self.queueContext else {
            return
        }

        recordProgressGapIfNeeded(for: newStage)
        recordEnvironmentIfNeeded(for: newStage)
        stage = newStage
        self.queueContext = queueContext
        stageBeganAt = .now
        AdFreePassBackgroundRunLog.record(
            "stage noted \(newStage.backgroundRunLogDescription) finished=\(queueContext.finishedItemCount) total=\(queueContext.totalItemCount)"
        )

        guard state != .foregroundOnly else {
            return
        }
        guard state != .idle else {
            return
        }
        guard let handle else {
            return
        }

        apply(newStage, to: handle)
    }

    /// Queue-terminal events are coordinator-driven (decision 14): mid-queue
    /// per-episode completions and failures are progress only; this is the
    /// single place a run ends.
    func noteQueueTerminal(_ outcome: AdFreePassQueueTerminalOutcome) {
        AdFreePassBackgroundRunLog.record("queue terminal noted outcome=\(outcome)")

        switch state {
        case .idle:
            return
        case .foregroundOnly:
            resetRunState(keepsForegroundOnly: true)
            return
        case .submitted, .running:
            break
        }

        guard let handle else {
            terminalOutcomeNotedBeforeLaunch = outcome
            if state == .submitted {
                cancelSubmittedRequest(reason: "terminal")
            }
            return
        }

        finalize(outcome, handle: handle)
    }

    func reset() {
        creepTask?.cancel()
        creepTask = nil
        if let handle {
            complete(handle, success: false)
        } else if state == .submitted {
            cancelSubmittedRequest(reason: "reset")
        }
        resetRunState(keepsForegroundOnly: false, invalidatesRun: true)
    }

    private func registerLaunchHandlerIfNeeded() -> Bool {
        guard !hasRegisteredLaunchHandler else {
            return true
        }

        let didRegister = scheduler.registerLaunchHandler(identifier: Self.identifier) { [weak self] handle in
            self?.handleLaunch(handle)
        }
        hasRegisteredLaunchHandler = didRegister
        if didRegister {
            Self.logger.log("registered continued processing launch handler")
            AdFreePassBackgroundRunLog.record("register success identifier=\(Self.identifier)")
        } else {
            Self.logger.error("continued processing registration failed")
            AdFreePassBackgroundRunLog.record("register failed identifier=\(Self.identifier)")
        }
        return didRegister
    }

    private var canStartNewRun: Bool {
        switch state {
        case .idle, .foregroundOnly:
            true
        case .submitted:
            terminalOutcomeNotedBeforeLaunch != nil
        case .running:
            false
        }
    }

    private func handleLaunch(_ launchedHandle: any AdFreePassContinuedTaskHandle) {
        guard state == .submitted else {
            complete(launchedHandle, success: false)
            return
        }

        handle = launchedHandle
        state = .running
        launchedHandle.progress.totalUnitCount = AdFreePassQueueProgressMapper.totalUnitCount
        launchedHandle.progress.completedUnitCount = mapper.completedUnitCount
        let launchRunSequence = runSequence
        let cancellationSource = cancellationSource
        let expirationGate = expirationGate
        launchedHandle.setExpirationHandler { [weak self, cancellationSource, expirationGate, launchRunSequence] in
            guard expirationGate.pass() else {
                return
            }

            cancellationSource.cancel()
            Task { @MainActor in
                self?.expire(runSequence: launchRunSequence)
            }
        }
        Self.logger.log("continued processing launch handler fired")
        AdFreePassBackgroundRunLog.record("launch handler fired")
        AdFreePassBackgroundEnvironmentSnapshot.record(reason: "launch")

        apply(stage, to: launchedHandle)
        if let terminalOutcomeNotedBeforeLaunch {
            finalize(terminalOutcomeNotedBeforeLaunch, handle: launchedHandle)
        }
    }

    private func expire(runSequence launchedRunSequence: Int) {
        guard launchedRunSequence == runSequence else {
            return
        }

        Self.logger.log("continued processing task expired")
        AdFreePassBackgroundRunLog.record("expiration handler fired")
        creepTask?.cancel()
        creepTask = nil
        onExpiration?()

        if let handle {
            complete(handle, success: false)
            resetRunState(keepsForegroundOnly: false)
            return
        }

        resetRunState(keepsForegroundOnly: false)
    }

    private func apply(
        _ stage: EpisodeAdFreePassStage,
        to handle: any AdFreePassContinuedTaskHandle
    ) {
        guard !hasCompletedTask else {
            return
        }

        let units = mapper.update(for: stage, queueContext: queueContext, stageElapsed: 0)
        handle.progress.completedUnitCount = units
        handle.updateTitle(title(for: queueContext), subtitle: subtitle(for: stage))
        recordAppliedStage(stage, completedUnits: units)
        updateCreepTask(for: stage)
    }

    private func finalize(
        _ outcome: AdFreePassQueueTerminalOutcome,
        handle: any AdFreePassContinuedTaskHandle
    ) {
        switch outcome {
        case .drained(let completedCount, _):
            let success = completedCount >= 1
            if success {
                handle.progress.completedUnitCount = mapper.markDrained()
            }
            complete(handle, success: success)
        case .awaitingConsent:
            handle.updateTitle(title(for: queueContext), subtitle: Self.consentSubtitle)
            complete(handle, success: false)
        case .capDeferred:
            handle.updateTitle(title(for: queueContext), subtitle: Self.capDeferredSubtitle)
            complete(handle, success: false)
        case .interrupted:
            complete(handle, success: false)
        }
        resetRunState(keepsForegroundOnly: false)
    }

    private func updateCreepTask(for stage: EpisodeAdFreePassStage) {
        creepTask?.cancel()
        creepTask = nil

        guard stage.creepsBackgroundProgress else {
            return
        }

        creepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.creepInterval)
                } catch {
                    return
                }

                self?.advanceCreep()
            }
        }
    }

    private func advanceCreep() {
        guard let handle,
              stage.creepsBackgroundProgress,
              !hasCompletedTask
        else {
            return
        }

        let units = mapper.update(
            for: stage,
            queueContext: queueContext,
            stageElapsed: Date.now.timeIntervalSince(stageBeganAt)
        )
        handle.progress.completedUnitCount = units
        recordAppliedStage(stage, completedUnits: units)
    }

    private func complete(_ handle: any AdFreePassContinuedTaskHandle, success: Bool) {
        guard completionGate.pass() else {
            return
        }
        hasCompletedTask = true
        creepTask?.cancel()
        creepTask = nil
        handle.setTaskCompleted(success: success)
        Self.logger.log("continued processing task completed success=\(success)")
        AdFreePassBackgroundRunLog.record("task completed success=\(success)")
    }

    private func cancelSubmittedRequest(reason: String) {
        scheduler.cancel(identifier: Self.identifier)
        Self.logger.log("cancelled submitted continued processing request reason=\(reason, privacy: .public)")
        AdFreePassBackgroundRunLog.record("submit cancelled reason=\(reason) identifier=\(Self.identifier)")
    }

    private func recordAppliedStage(_ stage: EpisodeAdFreePassStage, completedUnits: Int64) {
        let summary = stage.backgroundRunLogDescription
        let previousUnits = lastLoggedCompletedUnits
        let shouldLog = summary != lastLoggedStageSummary
            || previousUnits == nil
            || completedUnits - (previousUnits ?? 0) >= 10

        guard shouldLog else {
            return
        }

        lastLoggedStageSummary = summary
        lastLoggedCompletedUnits = completedUnits
        AdFreePassBackgroundRunLog.record("stage applied units=\(completedUnits)/\(AdFreePassQueueProgressMapper.totalUnitCount) \(summary)")
    }

    private func title(for context: AdFreePassQueueContext) -> String {
        guard context.totalItemCount > 1 else {
            return Self.title
        }

        let position = min(context.finishedItemCount + 1, context.totalItemCount)
        return Self.truncatedTitleText(
            "Detecting ads — \(position) of \(context.totalItemCount) · \(context.episodeTitle)"
        )
    }

    private func subtitle(for stage: EpisodeAdFreePassStage) -> String {
        EpisodeAdFreePassPresentation(stage: stage).statusText
    }

    private func resetRunState(keepsForegroundOnly: Bool, invalidatesRun: Bool = false) {
        if invalidatesRun {
            runSequence += 1
        }
        handle = nil
        mapper.reset()
        stage = .idle
        queueContext = AdFreePassQueueContext()
        stageBeganAt = .now
        terminalOutcomeNotedBeforeLaunch = nil
        hasCompletedTask = false
        completionGate = AdFreePassOnceGate()
        expirationGate = AdFreePassOnceGate()
        state = keepsForegroundOnly ? .foregroundOnly : .idle
        lastLoggedStageSummary = nil
        lastLoggedCompletedUnits = nil
        lastLoggedEnvironmentStageKey = nil
        lastTranscribingProgressLoggedAt = nil
        lastTranscribingCompletedDuration = nil
    }

    private static func truncatedTitleText(_ value: String) -> String {
        guard value.count > 60 else {
            return value
        }

        return "\(value.prefix(57))..."
    }

    private static func environmentForcesForegroundOnly() -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["OPENCAST_ADFREEPASS_FORCE_FOREGROUND_ONLY"] == "1"
        #else
        false
        #endif
    }
}

private extension EpisodeAdFreePassStage {
    var creepsBackgroundProgress: Bool {
        switch self {
        case .downloadingEpisode, .analyzing, .transcribing:
            true
        case .idle, .awaitingModelDownloadConsent, .installingModel, .installingSpeechAssets,
             .cloudQueued, .cloudTranscribing, .cloudDetectingAds, .cloudUnavailable,
             .completed, .interrupted, .failed, .unavailable:
            // Cloud stages never run under the background session at all.
            false
        }
    }
}

private extension EpisodeAdFreePassBackgroundSession {
    func recordEnvironmentIfNeeded(for stage: EpisodeAdFreePassStage) {
        let key = stage.backgroundLogStageKind
        guard key != lastLoggedEnvironmentStageKey else {
            return
        }

        lastLoggedEnvironmentStageKey = key
        AdFreePassBackgroundEnvironmentSnapshot.record(reason: "stage-\(key)")
    }

    func recordProgressGapIfNeeded(for stage: EpisodeAdFreePassStage) {
        guard case .transcribing(let progress) = stage else {
            lastTranscribingProgressLoggedAt = nil
            lastTranscribingCompletedDuration = nil
            return
        }

        let now = Date.now
        if let lastTranscribingProgressLoggedAt {
            let wallGap = now.timeIntervalSince(lastTranscribingProgressLoggedAt)
            let completedGap = progress.completedDuration - (lastTranscribingCompletedDuration ?? progress.completedDuration)
            AdFreePassBackgroundRunLog.record(
                "progress gap wall=\(wallGap.backgroundLogSeconds) completedDelta=\(completedGap.backgroundLogSeconds) completed=\(progress.completedDuration.backgroundLogSeconds) checkpoints=\(progress.checkpointCount) window=\(progress.currentWindowIndex.map(String.init) ?? "nil")"
            )
        }

        lastTranscribingProgressLoggedAt = now
        lastTranscribingCompletedDuration = progress.completedDuration
    }
}

private extension EpisodeAdFreePassPresentation {
    init(stage: EpisodeAdFreePassStage) {
        switch stage {
        case .idle:
            self = .idle
        case .awaitingModelDownloadConsent(let byteCount):
            self = .awaitingModelConsent(byteCount: byteCount)
        case .downloadingEpisode:
            self = .downloadingEpisode
        case .installingModel(let progress):
            self = .installingModel(progress)
        case .installingSpeechAssets(let fractionCompleted):
            self = .installingSpeechAssets(fractionCompleted: fractionCompleted)
        case .transcribing(let progress):
            self = .transcribing(progress)
        case .analyzing:
            self = .analyzing
        case .cloudQueued:
            self = .cloudQueued
        case .cloudTranscribing(let progress):
            self = .cloudTranscribing(progress)
        case .cloudDetectingAds:
            self = .cloudDetectingAds
        case .cloudUnavailable(let message):
            self = .cloudUnavailable(message)
        case .completed(let zoneCount):
            self = .completed(zoneCount: zoneCount)
        case .interrupted:
            self = .interrupted
        case .failed(let message):
            self = .failed(message)
        case .unavailable(let message):
            self = .unavailable(message)
        }
    }
}
