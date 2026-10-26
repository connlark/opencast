import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode ad-free pass background session")
struct EpisodeAdFreePassBackgroundSessionTests {
    @Test("Arming registers once and submits each run")
    func armingRegistersOnceAndSubmitsEachRun() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let firstHandle = FakeAdFreePassContinuedTaskHandle()
        let secondHandle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "First Episode")
        scheduler.launch(firstHandle)
        session.noteStage(.completed(zoneCount: 2))
        session.noteQueueTerminal(.drained(completedCount: 1, failedCount: 0))
        session.arm(episodeTitle: "Second Episode")
        scheduler.launch(secondHandle)

        #expect(scheduler.registerCallCount == 1)
        #expect(scheduler.submitCallCount == 2)
        #expect(firstHandle.completions == [true])
        #expect(session.isProtectingBackgroundExecution)
        #expect(session.isArmed)
    }

    @Test("Submission failure degrades to foreground-only")
    func submissionFailureDegradesToForegroundOnly() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler(submitError: ProbeError.submission)
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)

        session.arm(episodeTitle: "Foreground Episode")
        session.noteStage(.transcribing(transcriptionProgress(0.5)))

        #expect(scheduler.registerCallCount == 1)
        #expect(scheduler.submitCallCount == 1)
        #expect(!session.isProtectingBackgroundExecution)
        #expect(!session.isArmed)
    }

    @Test("GPU-granted platforms submit with GPU required; others never ask")
    func gpuSubmissionFollowsPlatformSupport() {
        let gpuScheduler = FakeAdFreePassContinuedTaskScheduler()
        gpuScheduler.supportsGPUResources = true
        let gpuSession = EpisodeAdFreePassBackgroundSession(scheduler: gpuScheduler)

        gpuSession.arm(episodeTitle: "GPU Episode")

        #expect(gpuScheduler.submittedGPUFlags == [true])
        #expect(gpuSession.isArmed)
        #expect(!gpuSession.requiresNonGPUCompute)

        let pinnedScheduler = FakeAdFreePassContinuedTaskScheduler()
        let pinnedSession = EpisodeAdFreePassBackgroundSession(scheduler: pinnedScheduler)

        pinnedSession.arm(episodeTitle: "Pinned Episode")

        #expect(pinnedScheduler.submittedGPUFlags == [false])
        #expect(pinnedSession.isArmed)
        #expect(!pinnedSession.requiresNonGPUCompute)
    }

    @Test("A failed GPU submission retries once without GPU before arming")
    func failedGPUSubmissionRetriesOnceWithoutGPU() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        scheduler.supportsGPUResources = true
        scheduler.submitErrorsByCall = [ProbeError.submission, nil]
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Ladder Episode")
        scheduler.launch(handle)
        session.noteStage(.analyzing(steps: nil))

        #expect(scheduler.submittedGPUFlags == [true, false])
        #expect(session.requiresNonGPUCompute)
        #expect(session.isProtectingBackgroundExecution)
        #expect(handle.titleUpdates.last?.subtitle == "Detecting ads")
    }

    @Test("An exhausted GPU retry ladder degrades to foreground-only")
    func exhaustedGPURetryLadderDegradesToForegroundOnly() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        scheduler.supportsGPUResources = true
        scheduler.submitErrorsByCall = [ProbeError.submission, ProbeError.submission]
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)

        session.arm(episodeTitle: "Exhausted Ladder Episode")
        session.noteStage(.analyzing(steps: nil))

        #expect(scheduler.submittedGPUFlags == [true, false])
        #expect(!session.requiresNonGPUCompute)
        #expect(!session.isArmed)
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("A non-GPU submission failure never retries")
    func nonGPUSubmissionFailureNeverRetries() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler(submitError: ProbeError.submission)
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)

        session.arm(episodeTitle: "No Retry Episode")

        #expect(scheduler.submittedGPUFlags == [false])
        #expect(scheduler.submitCallCount == 1)
        #expect(!session.isArmed)
    }

    @Test("Debug force flag degrades to foreground-only before registration")
    func debugForceFlagDegradesBeforeRegistration() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(
            scheduler: scheduler,
            forceForegroundOnly: { true }
        )

        session.arm(episodeTitle: "Forced Foreground Episode")
        session.noteStage(.transcribing(transcriptionProgress(0.5)))

        #expect(scheduler.registerCallCount == 0)
        #expect(scheduler.submitCallCount == 0)
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("Stage flow drives monotonic progress")
    func stageFlowDrivesMonotonicProgress() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Progress Episode")
        scheduler.launch(handle)
        session.noteStage(.transcribing(transcriptionProgress(0.75)))
        #expect(handle.adFreeUnits == 737)

        session.noteStage(.installingModel(installProgress(1)))
        #expect(handle.adFreeUnits == 737)

        session.noteStage(.analyzing(steps: nil))
        #expect(handle.adFreeUnits == 910)
        #expect(handle.titleUpdates.last?.subtitle == "Detecting ads")
        #expect(handle.titleUpdates.last?.title == "Skip Promos & Ads")
    }

    @Test("Cloud stages submit without GPU, stay monotonic, and creep while the server works")
    func cloudStagesSubmitWithoutGPUAndCreep() async {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        scheduler.supportsGPUResources = true
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Cloud Episode", requiresGPU: false)
        #expect(scheduler.submittedGPUFlags == [false])
        scheduler.launch(handle)

        session.noteStage(.cloudQueued)
        #expect(handle.adFreeUnits == 20)
        session.noteStage(.cloudTranscribing(nil))
        #expect(handle.adFreeUnits == 250)
        session.noteStage(.cloudFinishing)
        #expect(handle.adFreeUnits == 900)
        #expect(handle.titleUpdates.last?.subtitle == "Finishing the transcript in the cloud")

        // A server phase can hold one poll state for minutes; the creep (one
        // tick every 2 s) keeps the system from reading the card as stalled.
        // The 10 s budget is several ticks.
        #expect(await waitUntil(timeout: .seconds(10)) { handle.adFreeUnits > 900 })
        let crept = handle.adFreeUnits
        session.noteStage(.cloudTranscribing(nil))
        #expect(handle.adFreeUnits >= crept)
        #expect(handle.completions.isEmpty)
    }

    @Test("Cloud preparation stages share one creep clock, and upload part counts reach the subtitle")
    func cloudPreparationSharesOneCreepClock() async {
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler, now: { currentDate })
        let handle = FakeAdFreePassContinuedTaskHandle()
        session.arm(episodeTitle: "Cloud Episode", requiresGPU: false)
        scheduler.launch(handle)

        session.noteStage(.cloudVerifying)
        #expect(handle.adFreeUnits == 20)
        #expect(handle.titleUpdates.last?.subtitle == "Verifying audio…")

        // 20 s on the stage clock is 10 creep units, applied on the next tick.
        currentDate += 20
        #expect(await waitUntil { handle.adFreeUnits == 30 })

        // A move to the upload and each part count keep that clock; a
        // restart here would hold the card at 30 until the system expired it.
        session.noteStage(.cloudUploadingExactCopy(completedParts: 0, totalParts: 0))
        #expect(handle.titleUpdates.last?.subtitle == "Preparing audio upload…")
        session.noteStage(.cloudUploadingExactCopy(completedParts: 1, totalParts: 3))
        #expect(handle.titleUpdates.last?.subtitle == "Uploading audio… 1 of 3 parts uploaded")
        currentDate += 20
        #expect(await waitUntil { handle.adFreeUnits == 40 })
        session.noteStage(.cloudUploadingExactCopy(completedParts: 3, totalParts: 3))
        #expect(handle.titleUpdates.last?.subtitle == "Finishing audio upload…")
        #expect(handle.adFreeUnits == 40)

        // Server transcription is a new band with its own clock.
        session.noteStage(.cloudTranscribing(nil))
        #expect(handle.adFreeUnits == 250)
        #expect(handle.completions.isEmpty)
    }

    @Test("Frequent upload part events advance background progress without waiting for a creep tick")
    func uploadPartEventsAdvanceProgressBeforeCreepTick() {
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler, now: { currentDate })
        let handle = FakeAdFreePassContinuedTaskHandle()
        session.arm(episodeTitle: "Cloud Episode", requiresGPU: false)
        scheduler.launch(handle)
        defer { session.reset() }

        session.noteStage(.cloudUploadingExactCopy(completedParts: 0, totalParts: 10))
        #expect(handle.adFreeUnits == 20)

        // Synchronous events cannot yield to the timer; each event must
        // apply the elapsed preparation time itself.
        for completedParts in 1...8 {
            currentDate += 1
            session.noteStage(.cloudUploadingExactCopy(completedParts: completedParts, totalParts: 10))
        }

        #expect(handle.adFreeUnits == 24)
        #expect(handle.titleUpdates.last?.subtitle == "Uploading audio… 8 of 10 parts uploaded")
        #expect(handle.completions.isEmpty)
    }

    @Test("One submission covers a whole queue drain with per-episode title updates")
    func oneSubmissionCoversQueueDrainWithPerEpisodeTitles() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "First Episode")
        scheduler.launch(handle)
        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 3, episodeTitle: "First Episode")
        )
        #expect(handle.titleUpdates.last?.title == "Detecting ads — 1 of 3 · First Episode")

        session.noteStage(
            .completed(zoneCount: 2),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 3, episodeTitle: "First Episode")
        )
        // Mid-queue per-episode completion is progress only, never terminal.
        #expect(handle.completions.isEmpty)

        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 3, episodeTitle: "Second Episode")
        )
        #expect(handle.titleUpdates.last?.title == "Detecting ads — 2 of 3 · Second Episode")

        session.noteStage(
            .failed(message: "probe"),
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 3, episodeTitle: "Second Episode")
        )
        #expect(handle.completions.isEmpty)

        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 2, totalItemCount: 3, episodeTitle: "Third Episode")
        )
        #expect(handle.titleUpdates.last?.title == "Detecting ads — 3 of 3 · Third Episode")

        session.noteQueueTerminal(.drained(completedCount: 2, failedCount: 1))

        #expect(scheduler.submitCallCount == 1)
        #expect(handle.completions == [true])
        #expect(handle.adFreeUnits == 1_000)
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("Composite progress is monotonic and holds flat when items are appended mid-run")
    func compositeProgressHoldsFlatOnAppend() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "First Episode")
        scheduler.launch(handle)
        session.noteStage(
            .transcribing(transcriptionProgress(0.75)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 2, episodeTitle: "First Episode")
        )
        #expect(handle.adFreeUnits == 368)

        // Appending grows the denominator; progress holds flat rather than
        // running backwards.
        session.noteStage(
            .transcribing(transcriptionProgress(0.8)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 3, episodeTitle: "First Episode")
        )
        #expect(handle.adFreeUnits == 368)

        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 3, episodeTitle: "Second Episode")
        )
        #expect(handle.adFreeUnits == 368)

        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 2, totalItemCount: 3, episodeTitle: "Third Episode")
        )
        #expect(handle.adFreeUnits == 673)
    }

    @Test("Queue-terminal outcomes map to the settled success truth table")
    func queueTerminalSuccessTruthTable() {
        let cases: [(AdFreePassQueueTerminalOutcome, Bool)] = [
            (.drained(completedCount: 3, failedCount: 0), true),
            (.drained(completedCount: 1, failedCount: 2), true),
            (.drained(completedCount: 0, failedCount: 2), false),
            (.interrupted, false),
            (.remoteParked(.parked), false),
            (.remoteParked(.connectionLost), false),
            (.cloudUserCancelled, false),
            (.awaitingConsent, false)
        ]

        for (outcome, expectedSuccess) in cases {
            let scheduler = FakeAdFreePassContinuedTaskScheduler()
            let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
            let handle = FakeAdFreePassContinuedTaskHandle()

            session.arm(episodeTitle: "Truth Table Episode")
            scheduler.launch(handle)
            session.noteStage(.analyzing(steps: nil))
            session.noteQueueTerminal(outcome)

            #expect(handle.completions == [expectedSuccess], "outcome \(outcome)")
            #expect(!session.isProtectingBackgroundExecution)
        }
    }

    @Test("The consent terminal publishes its settled subtitle")
    func consentTerminalSubtitle() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Consent Episode")
        scheduler.launch(handle)
        session.noteStage(.downloadingEpisode)
        session.noteStage(.awaitingModelDownloadConsent(byteCount: 75_000_000))
        session.noteQueueTerminal(.awaitingConsent)

        #expect(handle.completions == [false])
        #expect(handle.titleUpdates.last?.subtitle == "Needs your OK to download the speech model - open OpenCast.")
    }

    @Test("Device ad detection creeps inside each step's slice over the step budget and moves with every answered step")
    func analyzingStepsCreepInsideTheirSlice() async {
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler, now: { currentDate })
        let handle = FakeAdFreePassContinuedTaskHandle()
        session.arm(episodeTitle: "Long Episode")
        scheduler.launch(handle)
        defer { session.reset() }

        // Slice 910 to 923 with 12 units of room, paced over 100 s.
        session.noteStage(.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 0, total: 5, stepBudgetSeconds: 100)))
        #expect(handle.adFreeUnits == 910)
        #expect(handle.titleUpdates.last?.subtitle == "Detecting ads")

        // A tenth of the budget is one unit, applied on the next 2 s tick.
        currentDate += 10
        #expect(await waitUntil { handle.adFreeUnits == 911 })
        currentDate += 40
        #expect(await waitUntil { handle.adFreeUnits == 916 })
        // Past the budget it parks one unit short of the slice end (923),
        // not at the band's ceiling.
        currentDate += 600
        #expect(await waitUntil { handle.adFreeUnits == 922 })

        // The next answered step opens its slice at once on a fresh clock.
        session.noteStage(.analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 5, stepBudgetSeconds: 100)))
        #expect(handle.adFreeUnits == 923)
        currentDate += 25
        #expect(await waitUntil { handle.adFreeUnits == 926 })
        #expect(handle.completions.isEmpty)
    }

    @Test("A many-window run's card moves on every creep tick across a long step, below the step's end")
    func manyWindowCardMovesOnEveryTick() async {
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler, now: { currentDate })
        let handle = FakeAdFreePassContinuedTaskHandle()
        session.arm(episodeTitle: "Long Episode")
        scheduler.launch(handle)
        defer { session.reset() }
        let subunits = EpisodeAdFreePassBackgroundSession.progressSubunitsPerUnit
        #expect(handle.progress.totalUnitCount == 1_000 * subunits)

        // Forty windows and the step to come, third of five in the queue:
        // the step's slice is two points of the 0...1000 scale (925 to 927),
        // under half a point of the card.
        let context = AdFreePassQueueContext(finishedItemCount: 2, totalItemCount: 5, episodeTitle: "Long Episode")
        session.noteStage(
            .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 10, total: 41, stepBudgetSeconds: 250)),
            queueContext: context
        )
        let start = handle.progress.completedUnitCount
        // The step's end, as the card counts it.
        let stepEnd = (2 * 1_000 * subunits + (910 * subunits + 65 * subunits * 11 / 41)) / 5
        #expect(start == (2 * 1_000 * subunits + (910 * subunits + 65 * subunits * 10 / 41)) / 5)

        // Each tick 2 s along the clock moves the card, while the 0...1000
        // view of it stands still.
        var previous = start
        for _ in 1...3 {
            currentDate += 2
            #expect(await waitUntil { handle.progress.completedUnitCount > previous })
            previous = handle.progress.completedUnitCount
        }
        #expect(handle.adFreeUnits == start / subunits)

        // Late in the 250 s budget it still moves on every tick, short of
        // the step's end.
        currentDate += 230
        for _ in 1...2 {
            #expect(await waitUntil { handle.progress.completedUnitCount > previous })
            previous = handle.progress.completedUnitCount
            #expect(previous < stepEnd)
            currentDate += 2
        }
        #expect(handle.completions.isEmpty)
    }

    @Test("Expiration invokes the interruption hook and completes unsuccessfully")
    func expirationInvokesHookAndCompletes() async {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()
        let cancellationSource = AdFreePassCancellationSource()
        let passTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        var expirationCount = 0
        cancellationSource.start(passTask)
        session.onExpiration = {
            expirationCount += 1
        }

        session.arm(episodeTitle: "Expiring Episode", cancellationSource: cancellationSource)
        scheduler.launch(handle)
        handle.expire()
        handle.expire()

        #expect(cancellationSource.cancellationRequestCount == 1)
        #expect(passTask.isCancelled)
        #expect(await waitUntil { expirationCount == 1 })
        #expect(expirationCount == 1)
        #expect(handle.completions == [false])
        #expect(!session.isProtectingBackgroundExecution)

        session.noteQueueTerminal(.interrupted)
        #expect(handle.completions == [false])
    }

    @Test("A terminal noted before launch cancels the request and completes the late handle immediately")
    func terminalBeforeLaunchCompletesLateHandleImmediately() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Short Episode")
        session.noteStage(.completed(zoneCount: 1))
        session.noteQueueTerminal(.drained(completedCount: 1, failedCount: 0))
        #expect(scheduler.cancelledIdentifiers.count == 2)

        scheduler.launch(handle)

        #expect(handle.completions == [true])
        #expect(handle.adFreeUnits == 1_000)
        #expect(!session.isProtectingBackgroundExecution)
    }

    @Test("A later arm recovers when submission succeeded but no handle arrived")
    func laterArmRecoversAfterTerminalWithoutHandle() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "No Handle Episode")
        session.noteStage(.interrupted)
        session.noteQueueTerminal(.interrupted)
        session.arm(episodeTitle: "Retry Episode")
        scheduler.launch(handle)

        #expect(scheduler.submitCallCount == 2)
        #expect(session.isProtectingBackgroundExecution)
    }

    @Test("A mid-run arm seeds the launched handle at the current composite units")
    func midRunArmSeedsCurrentCompositeUnits() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        // Queue mid-drain, un-armed: the "Continue in Background" tap arms and
        // the coordinator republishes the current stage before launch.
        session.arm(episodeTitle: "Second Episode")
        session.noteStage(
            .transcribing(transcriptionProgress(0.5)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 2, episodeTitle: "Second Episode")
        )
        scheduler.launch(handle)

        #expect(handle.adFreeUnits == 787)
        #expect(handle.titleUpdates.last?.title == "Detecting ads — 2 of 2 · Second Episode")
        #expect(session.isProtectingBackgroundExecution)
    }

    @Test("Reset while submitted cancels pending request and permits a later arm")
    func resetWhileSubmittedCancelsPendingRequestAndPermitsLaterArm() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)

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
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
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

    @Test("Duplicate stages with unchanged queue context do not repeat handle updates")
    func duplicateStagesDoNotRepeatHandleUpdates() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
        let handle = FakeAdFreePassContinuedTaskHandle()

        session.arm(episodeTitle: "Duplicate Stage Episode")
        scheduler.launch(handle)
        session.noteStage(.analyzing(steps: nil))
        let updateCount = handle.titleUpdates.count
        let completedUnits = handle.adFreeUnits

        session.noteStage(.analyzing(steps: nil))

        #expect(handle.titleUpdates.count == updateCount)
        #expect(handle.adFreeUnits == completedUnits)
    }

    private func installProgress(_ fraction: Double) -> OpenCastWhisperModelInstallProgress {
        let totalByteCount: Int64 = 1_000
        return OpenCastWhisperModelInstallProgress(
            modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
            version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
            completedFileCount: Int(fraction * 10),
            totalFileCount: 10,
            completedByteCount: Int64(fraction * Double(totalByteCount)),
            totalByteCount: totalByteCount,
            currentFilePath: nil
        )
    }

    private func transcriptionProgress(_ fraction: Double) -> EpisodeTranscriptionProgress {
        EpisodeTranscriptionProgress(
            audioDuration: 1_000,
            completedDuration: 1_000 * fraction,
            checkpointCount: 1,
            currentWindowIndex: nil,
            currentText: nil
        )
    }

}

private enum ProbeError: Error {
    case submission
}

extension FakeAdFreePassContinuedTaskHandle {
    /// The ad-free card's progress on the 0...1000 scale.
    var adFreeUnits: Int64 {
        progress.completedUnitCount / EpisodeAdFreePassBackgroundSession.progressSubunitsPerUnit
    }
}
