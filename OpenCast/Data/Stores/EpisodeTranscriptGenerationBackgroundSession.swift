import Foundation
import Observation
import OSLog

/// System progress card for the generate-transcript flow: a
/// `BGContinuedProcessingTask` session mirroring
/// `EpisodeAdFreePassBackgroundSession`'s proven shape minus queue logic,
/// reusing the identifier-parameterized scheduler layer unchanged. Progress is
/// pulled through injected closures on a creep cadence because the phase
/// stream only carries phase transitions, not fractions.
@Observable
final class EpisodeTranscriptGenerationBackgroundSession {
    static let identifier = "com.connor.opencast.transcript-generation"

    private enum State: Equatable {
        case idle
        case submitted
        case running
        case foregroundOnly
    }

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TranscriptGenerationBackground")
    private static let title = "Generating Transcript"
    private static let pausedSubtitle = "Paused — open OpenCast to resume"
    private static let creepInterval: Duration = .seconds(2)

    @ObservationIgnored private let scheduler: any AdFreePassContinuedTaskScheduling
    @ObservationIgnored private let forceForegroundOnly: @MainActor () -> Bool
    @ObservationIgnored var installFraction: () -> Double? = { nil }
    @ObservationIgnored var transcriptionProgress: () -> EpisodeTranscriptionProgress? = { nil }
    @ObservationIgnored var onExpiration: (() -> Void)?

    private var state: State = .idle
    private var hasRegisteredLaunchHandler = false
    private var handle: (any AdFreePassContinuedTaskHandle)?
    private var mapper = EpisodeTranscriptGenerationProgressMapper()
    private var phase: EpisodeTranscriptionRequestPhase = .downloading
    private var phaseBeganAt = Date.now
    @ObservationIgnored private var creepTask: Task<Void, Never>?
    private var terminalPhaseNotedBeforeLaunch: EpisodeTranscriptionRequestPhase?
    private var hasCompletedTask = false
    private var runSequence = 0

    @ObservationIgnored private var completionGate = AdFreePassOnceGate()
    @ObservationIgnored private var expirationGate = AdFreePassOnceGate()

    init(
        scheduler: any AdFreePassContinuedTaskScheduling = BGTaskSchedulerAdFreePassScheduler(),
        forceForegroundOnly: @escaping @MainActor () -> Bool = EpisodeTranscriptGenerationBackgroundSession.environmentForcesForegroundOnly
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

    var isArmed: Bool {
        state == .submitted || state == .running
    }

    func arm(episodeTitle: String) {
        guard canStartNewRun else {
            assertionFailure("A background transcript generation session is already active.")
            return
        }

        if state == .submitted && handle == nil {
            cancelSubmittedRequest(reason: "rearm")
        }

        resetRunState(keepsForegroundOnly: false)
        runSequence += 1
        let subtitle = Self.truncatedTitleText(episodeTitle)
        AdFreePassBackgroundRunLog.record("transcript-generation arm episodeTitle=\(episodeTitle) subtitle=\(subtitle)")
        guard !forceForegroundOnly() else {
            state = .foregroundOnly
            AdFreePassBackgroundRunLog.record("transcript-generation arm foregroundOnly reason=debugForced")
            return
        }
        guard registerLaunchHandlerIfNeeded() else {
            state = .foregroundOnly
            AdFreePassBackgroundRunLog.record("transcript-generation arm foregroundOnly reason=registrationFailed")
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
            AdFreePassBackgroundRunLog.record("transcript-generation submit failed error=\(error.localizedDescription)")
        }
    }

    /// Same GPU retry ladder as the ad-free session: a GPU-required
    /// submission retries once without GPU before degrading to
    /// foreground-only.
    private func submitRequest(subtitle: String, requiresGPU: Bool) throws {
        do {
            try scheduler.submit(
                identifier: Self.identifier,
                title: Self.title,
                subtitle: subtitle,
                requiresGPU: requiresGPU
            )
            AdFreePassBackgroundRunLog.record("transcript-generation submit success identifier=\(Self.identifier) gpu=\(requiresGPU)")
        } catch {
            guard requiresGPU else {
                throw error
            }

            Self.logger.error("continued processing GPU submission failed, retrying without GPU: \(error.localizedDescription, privacy: .public)")
            AdFreePassBackgroundRunLog.record("transcript-generation submit gpu failed error=\(error.localizedDescription) retryingWithoutGPU=true")
            try scheduler.submit(
                identifier: Self.identifier,
                title: Self.title,
                subtitle: subtitle,
                requiresGPU: false
            )
            AdFreePassBackgroundRunLog.record("transcript-generation submit success identifier=\(Self.identifier) gpu=false afterGPURetry=true")
        }
    }

    func notePhase(_ newPhase: EpisodeTranscriptionRequestPhase) {
        guard newPhase != phase else {
            return
        }

        phase = newPhase
        phaseBeganAt = .now
        AdFreePassBackgroundRunLog.record("transcript-generation phase noted \(newPhase.backgroundRunLogDescription)")

        switch state {
        case .idle:
            return
        case .foregroundOnly:
            if newPhase.isTerminal {
                resetRunState(keepsForegroundOnly: true)
            }
            return
        case .submitted, .running:
            break
        }

        guard let handle else {
            if newPhase.isTerminal {
                terminalPhaseNotedBeforeLaunch = newPhase
                if state == .submitted {
                    cancelSubmittedRequest(reason: "terminal")
                }
            }
            return
        }

        if newPhase.isTerminal {
            finalize(newPhase, handle: handle)
        } else {
            apply(newPhase, to: handle)
        }
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
            AdFreePassBackgroundRunLog.record("transcript-generation register success identifier=\(Self.identifier)")
        } else {
            Self.logger.error("continued processing registration failed")
            AdFreePassBackgroundRunLog.record("transcript-generation register failed identifier=\(Self.identifier)")
        }
        return didRegister
    }

    private var canStartNewRun: Bool {
        switch state {
        case .idle, .foregroundOnly:
            true
        case .submitted:
            terminalPhaseNotedBeforeLaunch != nil
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
        launchedHandle.progress.totalUnitCount = EpisodeTranscriptGenerationProgressMapper.totalUnitCount
        launchedHandle.progress.completedUnitCount = mapper.completedUnitCount
        let launchRunSequence = runSequence
        let expirationGate = expirationGate
        launchedHandle.setExpirationHandler { [weak self, expirationGate, launchRunSequence] in
            guard expirationGate.pass() else {
                return
            }

            Task { @MainActor in
                self?.expire(runSequence: launchRunSequence)
            }
        }
        Self.logger.log("continued processing launch handler fired")
        AdFreePassBackgroundRunLog.record("transcript-generation launch handler fired")

        apply(phase, to: launchedHandle)
        if let terminalPhaseNotedBeforeLaunch {
            finalize(terminalPhaseNotedBeforeLaunch, handle: launchedHandle)
        }
    }

    private func expire(runSequence launchedRunSequence: Int) {
        guard launchedRunSequence == runSequence else {
            return
        }

        Self.logger.log("continued processing task expired")
        AdFreePassBackgroundRunLog.record("transcript-generation expiration handler fired")
        creepTask?.cancel()
        creepTask = nil
        onExpiration?()

        if let handle {
            complete(handle, success: false)
        }
        resetRunState(keepsForegroundOnly: false)
    }

    private func apply(
        _ phase: EpisodeTranscriptionRequestPhase,
        to handle: any AdFreePassContinuedTaskHandle
    ) {
        guard !hasCompletedTask else {
            return
        }

        handle.progress.completedUnitCount = updatedUnits(stageElapsed: 0)
        handle.updateTitle(Self.title, subtitle: Self.subtitle(for: phase))
        updateCreepTask(for: phase)
    }

    private func finalize(
        _ phase: EpisodeTranscriptionRequestPhase,
        handle: any AdFreePassContinuedTaskHandle
    ) {
        switch phase {
        case .completed:
            handle.progress.completedUnitCount = mapper.update(for: .completed)
            complete(handle, success: true)
        case .interrupted, .cancelled, .failed:
            handle.updateTitle(Self.title, subtitle: Self.pausedSubtitle)
            complete(handle, success: false)
        case .downloading, .preparingWhisper, .transcribingWhisper, .transcribingAppleSpeech:
            return
        }
        resetRunState(keepsForegroundOnly: false)
    }

    private func updateCreepTask(for phase: EpisodeTranscriptionRequestPhase) {
        creepTask?.cancel()
        creepTask = nil

        guard !phase.isTerminal else {
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
              !phase.isTerminal,
              !hasCompletedTask
        else {
            return
        }

        handle.progress.completedUnitCount = updatedUnits(
            stageElapsed: Date.now.timeIntervalSince(phaseBeganAt)
        )
    }

    private func updatedUnits(stageElapsed: TimeInterval) -> Int64 {
        mapper.update(
            for: phase,
            installFraction: installFraction(),
            transcriptionFraction: transcriptionProgress()?.fractionCompleted,
            stageElapsed: stageElapsed
        )
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
        AdFreePassBackgroundRunLog.record("transcript-generation task completed success=\(success)")
    }

    private func cancelSubmittedRequest(reason: String) {
        scheduler.cancel(identifier: Self.identifier)
        Self.logger.log("cancelled submitted continued processing request reason=\(reason, privacy: .public)")
        AdFreePassBackgroundRunLog.record("transcript-generation submit cancelled reason=\(reason) identifier=\(Self.identifier)")
    }

    private func resetRunState(keepsForegroundOnly: Bool, invalidatesRun: Bool = false) {
        if invalidatesRun {
            runSequence += 1
        }
        handle = nil
        mapper.reset()
        phase = .downloading
        phaseBeganAt = .now
        terminalPhaseNotedBeforeLaunch = nil
        hasCompletedTask = false
        completionGate = AdFreePassOnceGate()
        expirationGate = AdFreePassOnceGate()
        state = keepsForegroundOnly ? .foregroundOnly : .idle
    }

    private static func subtitle(for phase: EpisodeTranscriptionRequestPhase) -> String {
        switch phase {
        case .downloading:
            "Downloading episode..."
        case .preparingWhisper:
            "Preparing the speech model..."
        case .transcribingWhisper, .transcribingAppleSpeech:
            "Transcribing..."
        case .completed:
            "Transcript ready"
        case .interrupted, .cancelled, .failed:
            Self.pausedSubtitle
        }
    }

    private static func truncatedTitleText(_ value: String) -> String {
        guard value.count > 60 else {
            return value
        }

        return "\(value.prefix(57))..."
    }

    private static func environmentForcesForegroundOnly() -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPT_FORCE_FOREGROUND_ONLY"] == "1"
        #else
        false
        #endif
    }
}

extension EpisodeTranscriptionRequestPhase {
    var backgroundRunLogDescription: String {
        switch self {
        case .downloading:
            "downloading"
        case .preparingWhisper:
            "preparingWhisper"
        case .transcribingWhisper:
            "transcribingWhisper"
        case .transcribingAppleSpeech:
            "transcribingAppleSpeech"
        case .completed:
            "completed"
        case .interrupted:
            "interrupted"
        case .cancelled:
            "cancelled"
        case .failed(let message):
            "failed message=\(message)"
        }
    }
}
