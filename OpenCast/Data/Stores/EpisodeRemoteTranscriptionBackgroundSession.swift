import Foundation
import Observation
import OSLog

/// System progress card for Transcribe Remotely: a queue-less
/// `BGContinuedProcessingTask` session in the shape of
/// `EpisodeTranscriptGenerationBackgroundSession`, over the same
/// identifier-parameterized scheduler layer. The job runs on the server, so
/// the card never asks for GPU and never counts as local lifecycle
/// protection. Expiration hands the park to its owner, which stops local
/// polling and keeps the job's reference; this session never makes a server
/// decision. Phases from any other episode's run are ignored, so a launch
/// or activation re-attach never drives the card.
@Observable
final class EpisodeRemoteTranscriptionBackgroundSession {
    static let identifier = "com.connor.opencast.remote-transcription"
    static let title = "Transcribing Remotely"

    private enum State: Equatable {
        case idle
        case submitted
        case running
        case foregroundOnly
    }

    private typealias Mapper = EpisodeRemoteTranscriptionProgressMapper

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "RemoteTranscriptionBackground")
    private static let creepInterval: Duration = .seconds(2)

    @ObservationIgnored private let scheduler: any AdFreePassContinuedTaskScheduling
    @ObservationIgnored private let forceForegroundOnly: @MainActor () -> Bool
    /// The plain flow's store: the session's trail goes to its sink and
    /// carries its reference's ids.
    @ObservationIgnored var jobStore: RemoteTranscriptionJobStore?
    /// Called once per expired run, on the main actor, with its episode. It
    /// parks the run synchronously and returns the work the system task must
    /// outlive (the park's run ending and its notification decision), or nil.
    /// The task completes only after that work ends, within
    /// `expirationUnwindBudget`, so the paused notification is scheduled
    /// before iOS suspends the app.
    @ObservationIgnored var onExpiration: ((_ episodeID: String) -> Task<Void, Never>?)?
    /// How long an expiration waits for the park to unwind and deliver
    /// before the task completes anyway. The handler has a few seconds; a
    /// cancelled poll leg and a notification `add` take milliseconds.
    static let expirationUnwindBudget: Duration = .seconds(3)

    private var state: State = .idle
    private var hasRegisteredLaunchHandler = false
    private var handle: (any AdFreePassContinuedTaskHandle)?
    private var episodeID: String?
    private var mapper = Mapper()
    private var phase: RemoteTranscriptionRequestPhase = .preparing
    private var phaseBeganAt = Date.now
    private var creepBaseUnits: Int64 = 0
    @ObservationIgnored private var creepTask: Task<Void, Never>?
    private var endingPhaseNotedBeforeLaunch: RemoteTranscriptionRequestPhase?
    /// While an expiration waits for the park to unwind, an ending phase the
    /// run publishes is held here instead of completing the task early.
    private var isAwaitingExpirationHandling = false
    private var endingPhaseNotedDuringExpiration: RemoteTranscriptionRequestPhase?
    private var hasCompletedTask = false
    private var runSequence = 0
    @ObservationIgnored private var knownJobID: String?
    @ObservationIgnored private var knownClientRequestID: String?

    @ObservationIgnored private var completionGate = AdFreePassOnceGate()
    @ObservationIgnored private var expirationGate = AdFreePassOnceGate()

    init(
        scheduler: any AdFreePassContinuedTaskScheduling = BGTaskSchedulerAdFreePassScheduler(),
        forceForegroundOnly: @escaping @MainActor () -> Bool = EpisodeRemoteTranscriptionBackgroundSession.environmentForcesForegroundOnly
    ) {
        self.scheduler = scheduler
        self.forceForegroundOnly = forceForegroundOnly
    }

    deinit {
        creepTask?.cancel()
    }

    /// A launched task is live. Never lifecycle protection: the work it
    /// tracks runs on the server.
    var isRunning: Bool {
        handle != nil && state == .running
    }

    /// True while a live run holds the card. A run that ended before its
    /// task launched no longer holds it, so the next tap or another session
    /// can arm.
    var isArmed: Bool {
        switch state {
        case .running:
            true
        case .submitted:
            endingPhaseNotedBeforeLaunch == nil
        case .idle, .foregroundOnly:
            false
        }
    }

    func arm(episodeID: String, episodeTitle: String) {
        guard canStartNewRun else {
            assertionFailure("A background remote transcription session is already active.")
            return
        }

        if state == .submitted && handle == nil {
            cancelSubmittedRequest(reason: "rearm")
        }

        resetRunState(keepsForegroundOnly: false)
        runSequence += 1
        self.episodeID = episodeID
        let subtitle = Self.truncatedTitleText(episodeTitle)
        AdFreePassBackgroundRunLog.record("remote-transcription arm episodeTitle=\(episodeTitle) subtitle=\(subtitle)")
        guard !forceForegroundOnly() else {
            degradeToForegroundOnly(reason: "debugForced")
            return
        }
        guard registerLaunchHandlerIfNeeded() else {
            degradeToForegroundOnly(reason: "registrationFailed")
            return
        }

        do {
            cancelSubmittedRequest(reason: "pre-submit")
            try scheduler.submit(
                identifier: Self.identifier,
                title: Self.title,
                subtitle: subtitle,
                requiresGPU: false
            )
            state = .submitted
            Self.logger.log("submitted continued processing task")
            AdFreePassBackgroundRunLog.record("remote-transcription submit success identifier=\(Self.identifier) gpu=false")
            record(.sessionArmed)
        } catch {
            Self.logger.error("continued processing submission failed: \(error.localizedDescription, privacy: .public)")
            AdFreePassBackgroundRunLog.record("remote-transcription submit failed error=\(error.localizedDescription)")
            degradeToForegroundOnly(reason: "submitFailed")
        }
    }

    /// The one-card guard refused this run before it reached the scheduler.
    func recordRefusedArm(episodeID: String) {
        AdFreePassBackgroundRunLog.record("remote-transcription arm skipped reason=anotherCardArmed")
        record(.sessionForegroundOnly, episodeID: episodeID)
    }

    func notePhase(_ newPhase: RemoteTranscriptionRequestPhase, episodeID: String) {
        guard episodeID == self.episodeID, newPhase != phase else {
            return
        }

        phase = newPhase
        // The creep clock restarts only when real progress moves; ETA-only
        // re-projections and a repeated earlier phase keep it creeping.
        let baseUnits = Mapper.units(for: newPhase, currentUnits: mapper.completedUnitCount)
        if baseUnits > creepBaseUnits {
            creepBaseUnits = baseUnits
            phaseBeganAt = .now
        }
        AdFreePassBackgroundRunLog.record("remote-transcription phase noted \(newPhase.displayText)")

        switch state {
        case .idle:
            return
        case .foregroundOnly:
            if newPhase.endsBackgroundRun {
                resetRunState(keepsForegroundOnly: true)
            }
            return
        case .submitted, .running:
            break
        }

        refreshReferenceIdentity()
        if isAwaitingExpirationHandling {
            // The expiration completes the task once the park's run ending
            // has been delivered; finalizing here would end it first.
            if newPhase.endsBackgroundRun {
                endingPhaseNotedDuringExpiration = newPhase
            }
            return
        }
        guard let handle else {
            if newPhase.endsBackgroundRun {
                endingPhaseNotedBeforeLaunch = newPhase
                if state == .submitted {
                    cancelSubmittedRequest(reason: "terminal")
                }
            }
            return
        }

        if newPhase.endsBackgroundRun {
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

    private func degradeToForegroundOnly(reason: String) {
        state = .foregroundOnly
        AdFreePassBackgroundRunLog.record("remote-transcription arm foregroundOnly reason=\(reason)")
        record(.sessionForegroundOnly)
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
            AdFreePassBackgroundRunLog.record("remote-transcription register success identifier=\(Self.identifier)")
        } else {
            Self.logger.error("continued processing registration failed")
            AdFreePassBackgroundRunLog.record("remote-transcription register failed identifier=\(Self.identifier)")
        }
        return didRegister
    }

    private var canStartNewRun: Bool {
        switch state {
        case .idle, .foregroundOnly:
            true
        case .submitted:
            endingPhaseNotedBeforeLaunch != nil
        case .running:
            false
        }
    }

    private func handleLaunch(_ launchedHandle: any AdFreePassContinuedTaskHandle) {
        guard state == .submitted else {
            // A stray launch is not this run's task; its once-gates stay
            // untouched.
            launchedHandle.setTaskCompleted(success: false)
            return
        }

        handle = launchedHandle
        state = .running
        launchedHandle.progress.totalUnitCount = Mapper.totalUnitCount
        launchedHandle.progress.completedUnitCount = mapper.completedUnitCount
        let launchRunSequence = runSequence
        let expirationGate = expirationGate
        launchedHandle.setExpirationHandler { [weak self, expirationGate, launchRunSequence] in
            guard expirationGate.pass() else {
                return
            }

            Task { @MainActor in
                await self?.expire(runSequence: launchRunSequence)
            }
        }
        Self.logger.log("continued processing launch handler fired")
        AdFreePassBackgroundRunLog.record("remote-transcription launch handler fired")
        record(.sessionLaunched)

        apply(phase, to: launchedHandle)
        if let endingPhaseNotedBeforeLaunch {
            finalize(endingPhaseNotedBeforeLaunch, handle: launchedHandle)
        }
    }

    private func expire(runSequence launchedRunSequence: Int) async {
        guard launchedRunSequence == runSequence, let episodeID else {
            return
        }

        Self.logger.log("continued processing task expired")
        AdFreePassBackgroundRunLog.record("remote-transcription expiration handler fired")
        creepTask?.cancel()
        creepTask = nil
        record(.sessionExpired)
        // The owner parks the run now, synchronously, so a run released from a
        // wait cannot slip a request in first. Completing the task right away
        // let iOS suspend the app before the park's run ending reached
        // delivery: on a locked phone the paused notification was created only
        // on the next unlock (SANDBOX SE, 2026-10-05). The task now waits for
        // that work, within its budget.
        if let pending = onExpiration?(episodeID) {
            isAwaitingExpirationHandling = true
            await awaitWithinBudget(pending)
            isAwaitingExpirationHandling = false
        }
        guard launchedRunSequence == runSequence else {
            return
        }

        if let handle, !hasCompletedTask {
            if let noted = endingPhaseNotedDuringExpiration {
                finalize(noted, handle: handle)
                return
            }
            handle.updateTitle(Self.title, subtitle: RemoteTranscriptionStatusPresentation.parkedTitle)
            complete(handle, success: false)
        }
        resetRunState(keepsForegroundOnly: false)
    }

    private func awaitWithinBudget(_ pending: Task<Void, Never>) async {
        let gate = AdFreePassOnceGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await pending.value
                if gate.pass() {
                    continuation.resume()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.expirationUnwindBudget)
                if gate.pass() {
                    AdFreePassBackgroundRunLog.record("remote-transcription expiration handling exceeded its budget")
                    continuation.resume()
                }
            }
        }
    }

    private func apply(
        _ phase: RemoteTranscriptionRequestPhase,
        to handle: any AdFreePassContinuedTaskHandle
    ) {
        guard !hasCompletedTask else {
            return
        }

        handle.progress.completedUnitCount = updatedUnits()
        handle.updateTitle(Self.title, subtitle: Self.subtitle(for: phase))
        updateCreepTask(for: phase)
    }

    private func finalize(
        _ phase: RemoteTranscriptionRequestPhase,
        handle: any AdFreePassContinuedTaskHandle
    ) {
        if phase == .completed {
            handle.progress.completedUnitCount = mapper.update(for: .completed)
            complete(handle, success: true)
        } else {
            handle.updateTitle(Self.title, subtitle: Self.subtitle(for: phase))
            complete(handle, success: false)
        }
        resetRunState(keepsForegroundOnly: false)
    }

    private func updateCreepTask(for phase: RemoteTranscriptionRequestPhase) {
        creepTask?.cancel()
        creepTask = nil

        guard !phase.endsBackgroundRun else {
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
              !phase.endsBackgroundRun,
              !hasCompletedTask
        else {
            return
        }

        handle.progress.completedUnitCount = updatedUnits()
    }

    private func updatedUnits() -> Int64 {
        mapper.update(for: phase, stageElapsed: Date.now.timeIntervalSince(phaseBeganAt))
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
        AdFreePassBackgroundRunLog.record("remote-transcription task completed success=\(success)")
        record(.sessionCompleted, disposition: referenceDisposition())
    }

    private func cancelSubmittedRequest(reason: String) {
        scheduler.cancel(identifier: Self.identifier)
        Self.logger.log("cancelled submitted continued processing request reason=\(reason, privacy: .public)")
        AdFreePassBackgroundRunLog.record("remote-transcription submit cancelled reason=\(reason) identifier=\(Self.identifier)")
    }

    private func resetRunState(keepsForegroundOnly: Bool, invalidatesRun: Bool = false) {
        if invalidatesRun {
            runSequence += 1
        }
        handle = nil
        episodeID = nil
        mapper.reset()
        phase = .preparing
        phaseBeganAt = .now
        creepBaseUnits = 0
        endingPhaseNotedBeforeLaunch = nil
        isAwaitingExpirationHandling = false
        endingPhaseNotedDuringExpiration = nil
        hasCompletedTask = false
        knownJobID = nil
        knownClientRequestID = nil
        completionGate = AdFreePassOnceGate()
        expirationGate = AdFreePassOnceGate()
        state = keepsForegroundOnly ? .foregroundOnly : .idle
    }

    // MARK: Diagnostics

    /// Keeps the run's ids after the reference clears, so the completion
    /// that follows a successful import still names its job.
    private func refreshReferenceIdentity() {
        guard let episodeID,
              let reference = jobStore?.existingReference(for: episodeID, purpose: .transcription)
        else {
            return
        }
        knownClientRequestID = reference.clientRequestID
        knownJobID = reference.jobID ?? knownJobID
    }

    /// The reference's state when the card ends: cleared after a delivered
    /// or terminal job, parked after an exit that kept it, retained otherwise.
    private func referenceDisposition() -> RemoteJobDiagnosticEvent.Disposition {
        guard let episodeID,
              let reference = jobStore?.existingReference(for: episodeID, purpose: .transcription)
        else {
            return .cleared
        }
        return reference.lastExit == nil ? .retained : .parked
    }

    private func record(
        _ kind: RemoteJobDiagnosticEvent.Kind,
        episodeID recordedEpisodeID: String? = nil,
        disposition: RemoteJobDiagnosticEvent.Disposition? = nil
    ) {
        guard let jobStore, let eventEpisodeID = recordedEpisodeID ?? episodeID else {
            return
        }
        var jobID: String?
        var clientRequestID: String?
        if eventEpisodeID == episodeID {
            refreshReferenceIdentity()
            jobID = knownJobID
            clientRequestID = knownClientRequestID
        } else if let reference = jobStore.existingReference(for: eventEpisodeID, purpose: .transcription) {
            jobID = reference.jobID
            clientRequestID = reference.clientRequestID
        }
        jobStore.diagnostics.record(RemoteJobDiagnosticEvent(
            component: .backgroundSession,
            kind: kind,
            episodeID: eventEpisodeID,
            jobID: jobID,
            clientRequestID: clientRequestID,
            purpose: .transcription,
            disposition: disposition
        ))
    }

    // MARK: Copy

    private static func subtitle(for phase: RemoteTranscriptionRequestPhase) -> String {
        switch phase {
        case .processing(let progress):
            guard let estimate = progress.estimate else {
                return phase.displayText
            }
            return "\(phase.displayText) · \(estimate.displayText)"
        case .parkedOnServer:
            return RemoteTranscriptionStatusPresentation.parkedTitle
        case .completed:
            return "Transcript ready"
        case .preparing, .downloadingBoth, .verifying, .uploadingExactCopy, .waitingForCredits,
             .saving, .mismatchLocalFallback, .failed, .cancelled:
            return phase.displayText
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
        ProcessInfo.processInfo.environment["OPENCAST_REMOTE_TRANSCRIPTION_FORCE_FOREGROUND_ONLY"] == "1"
        #else
        false
        #endif
    }
}

private extension RemoteTranscriptionRequestPhase {
    /// The local run is over: a terminal outcome, or a park that leaves the
    /// job running on the server for a later re-attach.
    var endsBackgroundRun: Bool {
        isTerminal || isParked
    }
}
