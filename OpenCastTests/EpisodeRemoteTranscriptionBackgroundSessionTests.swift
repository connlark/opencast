import Foundation
import Testing
@testable import OpenCast

/// The Transcribe Remotely system card, driven through the fake scheduler
/// and handle because the simulator never launches continued-processing
/// tasks: one registration, one GPU-less submission per run, monotonic
/// progress, one expiration that hands the park to its owner, and a
/// privacy-safe trail carrying the reference's ids.
@MainActor
@Suite("Episode remote transcription background session")
struct EpisodeRemoteTranscriptionBackgroundSessionTests {
    @Test("Arming registers once, submits each run without GPU, and completes a finished run successfully")
    func armingRegistersOnceAndSubmitsWithoutGPU() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        scheduler.supportsGPUResources = true
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let firstHandle = FakeAdFreePassContinuedTaskHandle()
        let secondHandle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-first", episodeTitle: "First Episode")
        scheduler.launch(firstHandle)
        session.notePhase(.completed, episodeID: "ep-first")
        session.arm(episodeID: "ep-second", episodeTitle: "Second Episode")
        scheduler.launch(secondHandle)

        #expect(scheduler.registerCallCount == 1)
        #expect(scheduler.submitCallCount == 2)
        #expect(scheduler.submittedGPUFlags == [false, false])
        #expect(firstHandle.completions == [true])
        #expect(firstHandle.progress.completedUnitCount == 1_000)
        #expect(secondHandle.progress.totalUnitCount == EpisodeRemoteTranscriptionProgressMapper.totalUnitCount)
        #expect(session.isRunning)
        #expect(session.isArmed)
    }

    @Test("A failed submission degrades to foreground-only with no GPU retry, and a later run can arm")
    func submissionFailureDegradesToForegroundOnly() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler(submitError: ProbeError.submission)
        scheduler.supportsGPUResources = true
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)

        session.arm(episodeID: "ep-foreground", episodeTitle: "Foreground Episode")
        session.notePhase(.downloadingBoth, episodeID: "ep-foreground")

        #expect(scheduler.registerCallCount == 1)
        #expect(scheduler.submittedGPUFlags == [false])
        #expect(!session.isRunning)
        #expect(!session.isArmed)

        session.notePhase(.parkedOnServer(.connectionLost), episodeID: "ep-foreground")
        session.arm(episodeID: "ep-foreground", episodeTitle: "Foreground Episode")
        #expect(scheduler.submitCallCount == 2)
    }

    @Test("The debug force flag degrades to foreground-only before registration")
    func debugForceFlagDegradesBeforeRegistration() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(
            scheduler: scheduler,
            forceForegroundOnly: { true }
        )

        session.arm(episodeID: "ep-forced", episodeTitle: "Forced Foreground Episode")
        session.notePhase(.verifying, episodeID: "ep-forced")

        #expect(scheduler.registerCallCount == 0)
        #expect(scheduler.submitCallCount == 0)
        #expect(!session.isArmed)
        #expect(!session.isRunning)
    }

    @Test("Phase flow drives monotonic progress and phase subtitles through regressions and ETA re-projection")
    func phaseFlowDrivesMonotonicProgressAndSubtitles() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()
        let episodeID = "ep-progress"

        session.arm(episodeID: episodeID, episodeTitle: "Progress Episode")
        session.notePhase(.preparing, episodeID: episodeID)
        scheduler.launch(handle)
        var observedUnits = [handle.progress.completedUnitCount]
        #expect(observedUnits[0] > 0)
        #expect(handle.titleUpdates.last?.title == EpisodeRemoteTranscriptionBackgroundSession.title)
        #expect(handle.titleUpdates.last?.subtitle == RemoteTranscriptionRequestPhase.preparing.displayText)

        let halfway = RemoteTranscriptionRequestPhase.processing(Self.progress(
            .transcribing,
            fraction: 0.5,
            estimate: .onTrack(remainingSeconds: 300)
        ))
        let phases: [RemoteTranscriptionRequestPhase] = [
            .downloadingBoth,
            .verifying,
            // The poll loop can report the job queued again after the source
            // was verified; the card must not move backwards.
            .downloadingBoth,
            .uploadingExactCopy(completedParts: 1, totalParts: 4),
            .waitingForCredits,
            .processing(Self.progress(.checkingAudioDetails)),
            halfway,
            // A re-projected, longer ETA and a lower reported fraction.
            .processing(Self.progress(.transcribing, fraction: 0.4, estimate: .delayed)),
            .processing(Self.progress(.finalizing, fraction: 1)),
            .saving,
        ]
        for phase in phases {
            session.notePhase(phase, episodeID: episodeID)
            observedUnits.append(handle.progress.completedUnitCount)
        }

        #expect(observedUnits == observedUnits.sorted())
        #expect(observedUnits.last! < 1_000)
        #expect(handle.titleUpdates.contains {
            $0.subtitle == "Transcribing · \(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 300).displayText)"
        })
        #expect(handle.titleUpdates.last?.subtitle == RemoteTranscriptionRequestPhase.saving.displayText)

        session.notePhase(.completed, episodeID: episodeID)
        #expect(handle.progress.completedUnitCount == 1_000)
        #expect(handle.completions == [true])
        #expect(!session.isArmed)
        #expect(!session.isRunning)
    }

    @Test("Duplicate phases do not repeat handle updates")
    func duplicatePhasesDoNotRepeatHandleUpdates() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-duplicate", episodeTitle: "Duplicate Phase Episode")
        scheduler.launch(handle)
        session.notePhase(.verifying, episodeID: "ep-duplicate")
        let updateCount = handle.titleUpdates.count
        let completedUnits = handle.progress.completedUnitCount

        session.notePhase(.verifying, episodeID: "ep-duplicate")

        #expect(handle.titleUpdates.count == updateCount)
        #expect(handle.progress.completedUnitCount == completedUnits)
    }

    @Test("Phases from another episode's run never drive or end the card")
    func otherEpisodePhasesAreIgnored() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-armed", episodeTitle: "Armed Episode")
        scheduler.launch(handle)
        let updateCount = handle.titleUpdates.count

        session.notePhase(.processing(Self.progress(.transcribing, fraction: 0.9)), episodeID: "ep-other")
        session.notePhase(.completed, episodeID: "ep-other")

        #expect(handle.titleUpdates.count == updateCount)
        #expect(handle.completions.isEmpty)
        #expect(session.isRunning)
    }

    @Test("Expiration fires once, hands the park to its owner, shows the server-still-working subtitle and completes unsuccessfully")
    func expirationParksOnceAndCompletesUnsuccessfully() async {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()
        var expiredEpisodeIDs: [String] = []
        session.onExpiration = { expiredEpisodeIDs.append($0); return nil }

        session.arm(episodeID: "ep-expiring", episodeTitle: "Expiring Episode")
        scheduler.launch(handle)
        session.notePhase(.processing(Self.progress(.transcribing, fraction: 0.3)), episodeID: "ep-expiring")
        let unitsAtExpiration = handle.progress.completedUnitCount
        handle.expire()
        handle.expire()

        #expect(await waitUntil { expiredEpisodeIDs == ["ep-expiring"] })
        #expect(handle.completions == [false])
        #expect(handle.titleUpdates.last?.subtitle == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(handle.progress.completedUnitCount == unitsAtExpiration)
        #expect(!session.isRunning)
        #expect(!session.isArmed)

        // The park the owner performs lands later; it never completes twice.
        session.notePhase(.parkedOnServer(.parked), episodeID: "ep-expiring")
        #expect(handle.completions == [false])
        #expect(expiredEpisodeIDs == ["ep-expiring"])
    }

    @Test("A park reported by the run ends the card with the server-still-working subtitle")
    func runParkEndsCardUnsuccessfully() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-lost", episodeTitle: "Connection Lost Episode")
        scheduler.launch(handle)
        session.notePhase(.parkedOnServer(.connectionLost), episodeID: "ep-lost")

        #expect(handle.completions == [false])
        #expect(handle.titleUpdates.last?.subtitle == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(!session.isArmed)
    }

    @Test("A terminal failure or a user cancel ends the card unsuccessfully with its own copy")
    func terminalEndsCardUnsuccessfully() {
        for phase in [
            RemoteTranscriptionRequestPhase.failed(.localRequestFailed),
            .cancelled,
            .mismatchLocalFallback,
        ] {
            let scheduler = FakeAdFreePassContinuedTaskScheduler()
            let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
            let handle = FakeAdFreePassContinuedTaskHandle()

            session.arm(episodeID: "ep-terminal", episodeTitle: "Terminal Episode")
            scheduler.launch(handle)
            session.notePhase(.verifying, episodeID: "ep-terminal")
            session.notePhase(phase, episodeID: "ep-terminal")

            #expect(handle.completions == [false])
            #expect(handle.titleUpdates.last?.subtitle == phase.displayText)
            #expect(!session.isArmed)
        }
    }

    @Test("A terminal noted before launch cancels the request and completes the late handle immediately")
    func terminalBeforeLaunchCompletesLateHandleImmediately() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-short", episodeTitle: "Short Episode")
        session.notePhase(.completed, episodeID: "ep-short")
        #expect(scheduler.cancelledIdentifiers == [
            EpisodeRemoteTranscriptionBackgroundSession.identifier,
            EpisodeRemoteTranscriptionBackgroundSession.identifier,
        ])
        // The run is over, so a late launch must not hold the one card.
        #expect(!session.isArmed)

        scheduler.launch(handle)

        #expect(handle.completions == [true])
        #expect(handle.progress.completedUnitCount == 1_000)
        #expect(!session.isRunning)
    }

    @Test("Reset while submitted cancels the request, reset while running completes the handle unsuccessfully, and both permit a later arm")
    func resetPermitsLaterArm() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        let runningHandle = FakeAdFreePassContinuedTaskHandle()
        let retryHandle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-pending", episodeTitle: "Pending Episode")
        session.reset()
        #expect(scheduler.cancelledIdentifiers.count == 2)
        #expect(!session.isArmed)

        session.arm(episodeID: "ep-running", episodeTitle: "Running Episode")
        scheduler.launch(runningHandle)
        session.reset()
        #expect(runningHandle.completions == [false])
        #expect(!session.isArmed)

        session.arm(episodeID: "ep-retry", episodeTitle: "Retry Episode")
        scheduler.launch(retryHandle)
        #expect(scheduler.submitCallCount == 3)
        #expect(session.isRunning)
    }

    // MARK: Diagnostics

    @Test("The trail records arm, launch, expiration and completion with the reference's ids, around the owner's park")
    func trailCarriesReferenceIDsThroughExpiration() async throws {
        let (store, diagnostics) = try Self.makeStore()
        let reference = Self.seedAttached(store, episodeID: "ep-trail", jobID: "job-trail")
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        session.jobStore = store
        session.onExpiration = { episodeID in
            store.recordExit(.parked, episodeID: episodeID)
            return nil
        }
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-trail", episodeTitle: "Trail Episode")
        scheduler.launch(handle)
        handle.expire()
        #expect(await waitUntil { diagnostics.events(of: .sessionCompleted).count == 1 })

        let sessionKinds: [RemoteJobDiagnosticEvent.Kind] = [
            .sessionArmed, .sessionLaunched, .sessionExpired, .parked, .sessionCompleted,
        ]
        #expect(diagnostics.kinds.filter(sessionKinds.contains) == sessionKinds)
        let sessionEvents = diagnostics.events.filter { $0.component == .backgroundSession }
        #expect(sessionEvents.count == 4)
        for event in sessionEvents {
            #expect(event.episodeID == "ep-trail")
            #expect(event.jobID == "job-trail")
            #expect(event.clientRequestID == reference.clientRequestID)
            #expect(event.purpose == .transcription)
        }
        #expect(diagnostics.events(of: .sessionCompleted).first?.disposition == .parked)
    }

    @Test("Completion after the reference is cleared still carries the job's ids")
    func completionAfterClearCarriesCachedIDs() throws {
        let (store, diagnostics) = try Self.makeStore()
        let reference = Self.seedAttached(store, episodeID: "ep-done", jobID: "job-done")
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: scheduler)
        session.jobStore = store
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeID: "ep-done", episodeTitle: "Done Episode")
        scheduler.launch(handle)
        session.notePhase(.saving, episodeID: "ep-done")
        store.clearReference(for: "ep-done")
        session.notePhase(.completed, episodeID: "ep-done")

        let completed = try #require(diagnostics.events(of: .sessionCompleted).first)
        #expect(completed.jobID == "job-done")
        #expect(completed.clientRequestID == reference.clientRequestID)
        #expect(completed.disposition == .cleared)
        #expect(handle.completions == [true])
    }

    @Test("A failed submission and a refused arm each record foreground-only; a refusal never touches the scheduler")
    func foregroundOnlyOutcomesAreRecorded() throws {
        let (store, diagnostics) = try Self.makeStore()
        let failing = FakeAdFreePassContinuedTaskScheduler(submitError: ProbeError.submission)
        let session = EpisodeRemoteTranscriptionBackgroundSession(scheduler: failing)
        session.jobStore = store

        session.arm(episodeID: "ep-failed-submit", episodeTitle: "Failed Submit")
        #expect(diagnostics.events(of: .sessionForegroundOnly).map(\.episodeID) == ["ep-failed-submit"])
        #expect(diagnostics.events(of: .sessionArmed).isEmpty)

        let idleScheduler = FakeAdFreePassContinuedTaskScheduler()
        let refusing = EpisodeRemoteTranscriptionBackgroundSession(scheduler: idleScheduler)
        refusing.jobStore = store
        refusing.recordRefusedArm(episodeID: "ep-refused")

        #expect(diagnostics.events(of: .sessionForegroundOnly).map(\.episodeID) == ["ep-failed-submit", "ep-refused"])
        #expect(diagnostics.events(of: .sessionForegroundOnly).allSatisfy {
            $0.component == .backgroundSession && $0.purpose == .transcription
        })
        #expect(idleScheduler.registerCallCount == 0)
        #expect(idleScheduler.submitCallCount == 0)
        #expect(!refusing.isArmed)
    }

    // MARK: Helpers

    private static func progress(
        _ stage: RemoteTranscriptionActiveStage,
        fraction: Double? = nil,
        estimate: RemoteTranscriptionEstimate? = nil
    ) -> RemoteTranscriptionActiveProgress {
        RemoteTranscriptionActiveProgress(
            stage: stage,
            completedChunks: nil,
            totalChunks: nil,
            fractionCompleted: fraction,
            estimate: estimate
        )
    }

    private static func makeStore() throws -> (RemoteTranscriptionJobStore, RecordingRemoteJobDiagnosticSink) {
        let suiteName = "remote-session-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let diagnostics = RecordingRemoteJobDiagnosticSink()
        return (RemoteTranscriptionJobStore(defaults: defaults, diagnostics: diagnostics), diagnostics)
    }

    @discardableResult
    private static func seedAttached(
        _ store: RemoteTranscriptionJobStore,
        episodeID: String,
        jobID: String
    ) -> RemoteTranscriptionJobReference {
        let minted = store.reference(for: episodeID)
        store.markCreateAttempted(episodeID: episodeID)
        store.attachJob(id: jobID, episodeID: episodeID)
        return minted
    }
}

private enum ProbeError: Error {
    case submission
}
