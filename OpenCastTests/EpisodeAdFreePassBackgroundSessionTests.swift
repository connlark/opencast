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

        let pinnedScheduler = FakeAdFreePassContinuedTaskScheduler()
        let pinnedSession = EpisodeAdFreePassBackgroundSession(scheduler: pinnedScheduler)

        pinnedSession.arm(episodeTitle: "Pinned Episode")

        #expect(pinnedScheduler.submittedGPUFlags == [false])
        #expect(pinnedSession.isArmed)
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
        session.noteStage(.analyzing)

        #expect(scheduler.submittedGPUFlags == [true, false])
        #expect(session.isProtectingBackgroundExecution)
        #expect(handle.titleUpdates.last?.subtitle == "Analyzing promos and ads...")
    }

    @Test("An exhausted GPU retry ladder degrades to foreground-only")
    func exhaustedGPURetryLadderDegradesToForegroundOnly() {
        let scheduler = FakeAdFreePassContinuedTaskScheduler()
        scheduler.supportsGPUResources = true
        scheduler.submitErrorsByCall = [ProbeError.submission, ProbeError.submission]
        let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)

        session.arm(episodeTitle: "Exhausted Ladder Episode")
        session.noteStage(.analyzing)

        #expect(scheduler.submittedGPUFlags == [true, false])
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
        #expect(handle.progress.completedUnitCount == 737)

        session.noteStage(.installingModel(installProgress(1)))
        #expect(handle.progress.completedUnitCount == 737)

        session.noteStage(.analyzing)
        #expect(handle.progress.completedUnitCount == 910)
        #expect(handle.titleUpdates.last?.subtitle == "Analyzing promos and ads...")
        #expect(handle.titleUpdates.last?.title == "Skip Promos & Ads")
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
        #expect(handle.progress.completedUnitCount == 1_000)
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
        #expect(handle.progress.completedUnitCount == 368)

        // Appending grows the denominator; progress holds flat rather than
        // running backwards.
        session.noteStage(
            .transcribing(transcriptionProgress(0.8)),
            queueContext: AdFreePassQueueContext(finishedItemCount: 0, totalItemCount: 3, episodeTitle: "First Episode")
        )
        #expect(handle.progress.completedUnitCount == 368)

        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 1, totalItemCount: 3, episodeTitle: "Second Episode")
        )
        #expect(handle.progress.completedUnitCount == 368)

        session.noteStage(
            .downloadingEpisode,
            queueContext: AdFreePassQueueContext(finishedItemCount: 2, totalItemCount: 3, episodeTitle: "Third Episode")
        )
        #expect(handle.progress.completedUnitCount == 673)
    }

    @Test("Queue-terminal outcomes map to the settled success truth table")
    func queueTerminalSuccessTruthTable() {
        let cases: [(AdFreePassQueueTerminalOutcome, Bool)] = [
            (.drained(completedCount: 3, failedCount: 0), true),
            (.drained(completedCount: 1, failedCount: 2), true),
            (.drained(completedCount: 0, failedCount: 2), false),
            (.interrupted, false),
            (.awaitingConsent, false),
            (.capDeferred, false)
        ]

        for (outcome, expectedSuccess) in cases {
            let scheduler = FakeAdFreePassContinuedTaskScheduler()
            let session = EpisodeAdFreePassBackgroundSession(scheduler: scheduler)
            let handle = FakeAdFreePassContinuedTaskHandle()

            session.arm(episodeTitle: "Truth Table Episode")
            scheduler.launch(handle)
            session.noteStage(.analyzing)
            session.noteQueueTerminal(outcome)

            #expect(handle.completions == [expectedSuccess], "outcome \(outcome)")
            #expect(!session.isProtectingBackgroundExecution)
        }
    }

    @Test("Consent and cap-deferred terminals publish the settled subtitles")
    func consentAndCapDeferredTerminalSubtitles() {
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

        let capScheduler = FakeAdFreePassContinuedTaskScheduler()
        let capSession = EpisodeAdFreePassBackgroundSession(scheduler: capScheduler)
        let capHandle = FakeAdFreePassContinuedTaskHandle()

        capSession.arm(episodeTitle: "Cap Episode")
        capScheduler.launch(capHandle)
        capSession.noteStage(.analyzing)
        capSession.noteQueueTerminal(.capDeferred)

        #expect(capHandle.completions == [false])
        #expect(capHandle.titleUpdates.last?.subtitle == "Daily detection limit reached — continues tomorrow")
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
        #expect(handle.progress.completedUnitCount == 1_000)
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

        #expect(handle.progress.completedUnitCount == 787)
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
        session.noteStage(.analyzing)
        let updateCount = handle.titleUpdates.count
        let completedUnits = handle.progress.completedUnitCount

        session.noteStage(.analyzing)

        #expect(handle.titleUpdates.count == updateCount)
        #expect(handle.progress.completedUnitCount == completedUnits)
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
