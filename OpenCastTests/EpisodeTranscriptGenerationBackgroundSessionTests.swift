import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcript generation background session")
struct EpisodeTranscriptGenerationBackgroundSessionTests {
    @Test("Arming registers once and submits each run")
    func armingRegistersOnceAndSubmitsEachRun() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let firstHandle = FakeAdFreePassContinuedTaskHandle()
        let secondHandle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "First Episode")
        scheduler.launch(firstHandle)
        session.notePhase(.completed)
        session.arm(episodeTitle: "Second Episode")
        scheduler.launch(secondHandle)

        #expect(scheduler.registerCallCount == 1)
        #expect(scheduler.submitCallCount == 2)
        #expect(firstHandle.completions == [true])
        #expect(firstHandle.progress.completedUnitCount == 1_000)
        #expect(session.isProtectingBackgroundExecution)
        #expect(session.isArmed)
    }

    @Test("Submission failure degrades to foreground-only")
    func submissionFailureDegradesToForegroundOnly() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler(submitError: ProbeError.submission)
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)

        session.arm(episodeTitle: "Foreground Episode")
        session.notePhase(.transcribingWhisper)

        #expect(scheduler.registerCallCount == 1)
        #expect(scheduler.submitCallCount == 1)
        #expect(!session.isProtectingBackgroundExecution)
        #expect(!session.isArmed)

        session.notePhase(.completed)
        session.arm(episodeTitle: "Retry Episode")
        #expect(scheduler.submitCallCount == 2)
    }

    @Test("A failed GPU submission retries once without GPU before arming")
    func failedGPUSubmissionRetriesOnceWithoutGPU() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        scheduler.supportsGPUResources = true
        scheduler.submitErrorsByCall = [ProbeError.submission, nil]
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Ladder Episode")
        scheduler.launch(handle)

        #expect(scheduler.submittedGPUFlags == [true, false])
        #expect(session.isProtectingBackgroundExecution)
    }

    @Test("Debug force flag degrades to foreground-only before registration")
    func debugForceFlagDegradesBeforeRegistration() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(
            scheduler: scheduler,
            forceForegroundOnly: { true }
        )

        session.arm(episodeTitle: "Forced Foreground Episode")
        session.notePhase(.transcribingWhisper)

        #expect(scheduler.registerCallCount == 0)
        #expect(scheduler.submitCallCount == 0)
        #expect(!session.isProtectingBackgroundExecution)

        session.notePhase(.failed("probe"))
        session.arm(episodeTitle: "Retry Episode")
        #expect(scheduler.registerCallCount == 0)
        #expect(!session.isArmed)
    }

    @Test("Phase flow drives monotonic progress and phase subtitles")
    func phaseFlowDrivesMonotonicProgressAndSubtitles() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()
        var transcriptionFraction: Double?
        session.transcriptionProgress = {
            transcriptionFraction.map {
                EpisodeTranscriptionProgress(
                    audioDuration: 100,
                    completedDuration: 100 * $0,
                    checkpointCount: 1
                )
            }
        }

        session.arm(episodeTitle: "Progress Episode")
        scheduler.launch(handle)
        #expect(handle.progress.completedUnitCount == 20)
        #expect(handle.titleUpdates.last?.title == "Generating Transcript")
        #expect(handle.titleUpdates.last?.subtitle == "Downloading episode...")

        session.notePhase(.preparingWhisper)
        #expect(handle.progress.completedUnitCount == 150)
        #expect(handle.titleUpdates.last?.subtitle == "Preparing the speech model...")

        transcriptionFraction = 0.5
        session.notePhase(.transcribingWhisper)
        #expect(handle.progress.completedUnitCount == 600)
        #expect(handle.titleUpdates.last?.subtitle == "Transcribing...")

        session.notePhase(.completed)
        #expect(handle.progress.completedUnitCount == 1_000)
        #expect(handle.completions == [true])
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("Interruption pauses the card and completes unsuccessfully")
    func interruptionPausesCardAndCompletesUnsuccessfully() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Interrupted Episode")
        scheduler.launch(handle)
        session.notePhase(.transcribingWhisper)
        session.notePhase(.interrupted)

        #expect(handle.completions == [false])
        #expect(handle.titleUpdates.last?.subtitle == "Paused — open OpenCast to resume")
        #expect(!session.isArmed)
    }

    @Test("Expiration invokes the interruption hook and completes unsuccessfully")
    func expirationInvokesHookAndCompletes() async {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()
        var expirationCount = 0
        session.onExpiration = {
            expirationCount += 1
        }

        session.arm(episodeTitle: "Expiring Episode")
        scheduler.launch(handle)
        handle.expire()
        handle.expire()

        #expect(await waitUntil { expirationCount == 1 })
        #expect(expirationCount == 1)
        #expect(handle.completions == [false])
        #expect(!session.isProtectingBackgroundExecution)

        session.notePhase(.interrupted)
        #expect(handle.completions == [false])
    }

    @Test("A terminal noted before launch cancels the request and completes the late handle immediately")
    func terminalBeforeLaunchCompletesLateHandleImmediately() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Short Episode")
        session.notePhase(.completed)
        #expect(scheduler.cancelledIdentifiers.count == 2)

        scheduler.launch(handle)

        #expect(handle.completions == [true])
        #expect(handle.progress.completedUnitCount == 1_000)
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("A later arm recovers when submission succeeded but no handle arrived")
    func laterArmRecoversAfterTerminalWithoutHandle() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "No Handle Episode")
        session.notePhase(.interrupted)
        session.arm(episodeTitle: "Retry Episode")
        scheduler.launch(handle)

        #expect(scheduler.submitCallCount == 2)
        #expect(session.isProtectingBackgroundExecution)
    }

    @Test("Reset while submitted cancels pending request and permits a later arm")
    func resetWhileSubmittedCancelsPendingRequestAndPermitsLaterArm() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)

        session.arm(episodeTitle: "Pending Episode")
        session.reset()
        session.arm(episodeTitle: "Retry Episode")

        #expect(scheduler.cancelledIdentifiers.count == 3)
        #expect(scheduler.submitCallCount == 2)
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("Reset while running completes the handle unsuccessfully and permits a later arm")
    func resetWhileRunningCompletesHandleAndPermitsLaterArm() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let firstHandle = FakeAdFreePassContinuedTaskHandle()
        let secondHandle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Running Episode")
        scheduler.launch(firstHandle)
        session.reset()
        session.arm(episodeTitle: "Retry Episode")
        scheduler.launch(secondHandle)

        #expect(firstHandle.completions == [false])
        #expect(scheduler.submitCallCount == 2)
        #expect(session.isProtectingBackgroundExecution)
    }

    @Test("Duplicate phases do not repeat handle updates")
    func duplicatePhasesDoNotRepeatHandleUpdates() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeTranscriptGenerationBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Duplicate Phase Episode")
        scheduler.launch(handle)
        session.notePhase(.preparingWhisper)
        let updateCount = handle.titleUpdates.count
        let completedUnits = handle.progress.completedUnitCount

        session.notePhase(.preparingWhisper)

        #expect(handle.titleUpdates.count == updateCount)
        #expect(handle.progress.completedUnitCount == completedUnits)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}

private enum ProbeError: Error {
    case submission
}
