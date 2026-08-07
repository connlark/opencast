import Foundation
@preconcurrency import MediaPlayer
import OpenCastCore
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct AVFoundationPlaybackControllerTests {
    @Test
    func loadThrowsForMissingAudioURL() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }

        let missingAudioEpisode = Episode(
            id: EpisodeID(rawValue: "missing-audio"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Missing Audio",
            duration: 120,
            audioURL: nil
        )

        #expect(throws: OpenCastCoreError.self) {
            try controller.load(missingAudioEpisode)
        }
    }

    @Test
    func unplayableLocalFileMovesToFailedState() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "opencast-invalid-playback-fixture.m4a")
        try Data("not an audio file".utf8).write(to: fileURL, options: .atomic)

        let controller = AVFoundationPlaybackController()
        let invalidEpisode = Episode(
            id: EpisodeID(rawValue: "invalid-audio"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Invalid Audio",
            duration: 120,
            audioURL: fileURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fileURL)
        }

        try controller.load(invalidEpisode)
        controller.play()

        let state = try await waitForTerminalPlaybackState(in: controller)
        guard case .failed(let message) = state else {
            Issue.record("Expected failed playback state, got \(state).")
            return
        }
        #expect(message.contains("could not be played"))
        #expect(controller.snapshot.progressBoundaryID > 0)

        controller.handleAudioSessionOldDeviceUnavailable()
        #expect(controller.snapshot.state == state)
    }

    @Test
    func retryAfterFailedLocalFileRebuildsPlaybackItem() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "opencast-retry-playback-\(UUID().uuidString).m4a")
        let validFixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        try Data("not an audio file".utf8).write(to: fileURL, options: .atomic)

        let controller = AVFoundationPlaybackController()
        let episode = Episode(
            id: EpisodeID(rawValue: "retry-audio"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Retry Audio",
            duration: 4,
            audioURL: fileURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: validFixtureURL)
        }

        try controller.load(episode, startPosition: 2)
        controller.play()

        let failedState = try await waitForTerminalPlaybackState(in: controller)
        guard case .failed = failedState else {
            Issue.record("Expected failed playback state before retry, got \(failedState).")
            return
        }
        #expect(controller.snapshot.position >= 2)

        try Data(contentsOf: validFixtureURL).write(to: fileURL, options: .atomic)
        controller.play()

        let recoveredState = try await waitForPlaybackState(in: controller) { state in
            state == .playing
        }
        #expect(recoveredState == .playing)
        #expect(controller.snapshot.position >= 2)
    }

    @Test
    func nowPlayingRateIsZeroWhileBuffering() throws {
        let builder = NowPlayingInfoBuilder()
        let snapshot = PlaybackSnapshot(
            state: .buffering,
            currentEpisode: episode(duration: 240),
            position: 30,
            duration: 240,
            rate: 1.5
        )

        let info = try #require(builder.info(for: snapshot, resolvedDuration: nil, artwork: nil))

        #expect(floatValue(info[MPNowPlayingInfoPropertyPlaybackRate]) == 0)
    }

    @Test
    func oldDeviceUnavailablePausesAndDoesNotRequestResume() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }

        try controller.load(episode(duration: 240))
        controller.play()
        controller.handleAudioSessionInterruptionBegan()
        let boundaryBeforeRouteChange = controller.snapshot.progressBoundaryID
        controller.handleAudioSessionOldDeviceUnavailable()

        #expect(controller.snapshot.state == .paused)
        #expect(controller.snapshot.progressBoundaryID == boundaryBeforeRouteChange + 1)

        controller.handleAudioSessionInterruptionEnded(shouldResume: true)

        #expect(controller.snapshot.state == .paused)
    }

    @Test
    func explicitPauseDuringInterruptionRevokesResumeIntent() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }

        try controller.load(episode(duration: 240))
        controller.isAudioSessionActive = true
        controller.play()
        controller.handleAudioSessionInterruptionBegan()
        controller.pause()
        controller.handleAudioSessionInterruptionEnded(shouldResume: true)

        #expect(controller.snapshot.state == .paused)
    }

    @Test(arguments: [true, false])
    func bufferingInterruptionResumesOnlyWhenOperatingSystemRequestsIt(
        operatingSystemShouldResume: Bool
    ) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
        }

        try controller.load(episode(duration: 240))
        controller.isAudioSessionActive = true
        controller.play()
        #expect(controller.snapshot.state == .buffering)

        controller.handleAudioSessionInterruptionBegan()
        #expect(controller.snapshot.state == .paused)

        controller.handleAudioSessionInterruptionEnded(
            shouldResume: operatingSystemShouldResume
        )

        if operatingSystemShouldResume {
            try await waitForActivationCalls(1, probe: probe)
            #expect(controller.snapshot.state == .loading)
        } else {
            #expect(controller.snapshot.state == .paused)
            #expect(await probe.recordedCallCount() == 0)
        }
    }

    @Test
    func interruptionMarksAudioSessionInactive() {
        let controller = AVFoundationPlaybackController()
        controller.isAudioSessionActive = true

        controller.handleAudioSessionInterruptionBegan()

        #expect(!controller.isAudioSessionActive)
    }

    @Test
    func playbackStallTransitionsToBufferingWithAutomaticWaitingEnabled() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let controller = AVFoundationPlaybackController()
        var startBehaviors: [PlaybackStartBehavior] = []
        controller.playbackStartBehaviorObserver = { startBehaviors.append($0) }
        defer {
            controller.unload()
        }

        try controller.load(episode(duration: 240))
        controller.setRate(1.5)
        controller.play()
        controller.handleCurrentItemPlaybackStalled()

        #expect(controller.snapshot.state == .buffering)
        #expect(controller.automaticallyWaitsToMinimizeStalling)
        #expect(controller.currentPlayerDefaultRate == 1.5)
        #expect(startBehaviors.last == .automaticBufferWaiting)
        #expect(!startBehaviors.dropLast().contains(.automaticBufferWaiting))
    }

    @Test(arguments: [true, false])
    func playingInterruptionResumesOnlyWhenOperatingSystemRequestsIt(
        operatingSystemShouldResume: Bool
    ) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(playbackEpisode(audioURL: fixtureURL))
        controller.isAudioSessionActive = true
        controller.play()
        _ = try await waitForPlaybackState(in: controller) { $0 == .playing }

        controller.handleAudioSessionInterruptionBegan()
        controller.handleAudioSessionInterruptionEnded(
            shouldResume: operatingSystemShouldResume
        )

        if operatingSystemShouldResume {
            try await waitForActivationCalls(1, probe: probe)
            await probe.releaseCalls(through: 1)
            #expect(try await waitForPlaybackState(in: controller) { $0 == .playing } == .playing)
        } else {
            #expect(controller.snapshot.state == .paused)
            #expect(await probe.recordedCallCount() == 0)
        }
    }

    @Test(arguments: [true, false])
    func pausedInterruptionNeverResumes(
        operatingSystemShouldResume: Bool
    ) async throws {
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
        }

        try controller.load(episode(duration: 240))
        controller.handleAudioSessionInterruptionBegan()
        controller.handleAudioSessionInterruptionEnded(
            shouldResume: operatingSystemShouldResume
        )

        #expect(controller.snapshot.state == .paused)
        #expect(await probe.recordedCallCount() == 0)
    }

    @Test
    func audioSessionActivationCompletesBeforePlayerStarts() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(playbackEpisode(audioURL: fixtureURL))
        controller.play()
        try await waitForActivationCalls(1, probe: probe)

        #expect(controller.snapshot.state == .loading)
        #expect(controller.currentPlayerRate == 0)

        await probe.releaseCalls(through: 1)
        let state = try await waitForPlaybackState(in: controller) { $0 == .playing }

        #expect(state == .playing)
        #expect(controller.currentPlayerRate > 0)
    }

    @Test
    func audioSessionActivationFailureCanRetryPlayback() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let probe = AudioSessionActivationProbe(outcomes: [.failure, .success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(playbackEpisode(audioURL: fixtureURL))
        controller.play()
        try await waitForActivationCalls(1, probe: probe)
        await probe.releaseCalls(through: 1)

        let failedState = try await waitForTerminalPlaybackState(in: controller)
        guard case .failed = failedState else {
            Issue.record("Expected activation failure, got \(failedState).")
            return
        }

        controller.play()
        try await waitForActivationCalls(2, probe: probe)
        await probe.releaseCalls(through: 2)

        let recoveredState = try await waitForPlaybackState(in: controller) { $0 == .playing }
        #expect(recoveredState == .playing)
    }

    @Test(arguments: [true, false])
    func loadingInterruptionResumesOnlyWhenOperatingSystemRequestsIt(
        operatingSystemShouldResume: Bool
    ) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let probe = AudioSessionActivationProbe(outcomes: [.success, .success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(playbackEpisode(audioURL: fixtureURL))
        controller.play()
        try await waitForActivationCalls(1, probe: probe)

        controller.handleAudioSessionInterruptionBegan()
        #expect(controller.snapshot.state == .paused)
        controller.handleAudioSessionInterruptionEnded(
            shouldResume: operatingSystemShouldResume
        )
        if operatingSystemShouldResume {
            try await waitForActivationCalls(2, probe: probe)
            await probe.releaseCalls(through: 2)
            let state = try await waitForPlaybackState(in: controller) { $0 == .playing }
            #expect(state == .playing)
        } else {
            #expect(controller.snapshot.state == .paused)
            #expect(await probe.recordedCallCount() == 1)
        }
    }

    @Test
    func toggleDuringActivationPausesWithoutLateStart() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(playbackEpisode(audioURL: fixtureURL))
        controller.play()
        try await waitForActivationCalls(1, probe: probe)
        #expect(controller.snapshot.state == .loading)

        controller.togglePlayPause()
        await probe.releaseCalls(through: 1)
        try await waitUntil { controller.isAudioSessionActive }

        #expect(controller.snapshot.state == .paused)
        #expect(controller.currentPlayerRate == 0)
    }

    @Test
    func rateChangeDuringActivationDoesNotStartPlayer() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() }
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(playbackEpisode(audioURL: fixtureURL))
        controller.play()
        try await waitForActivationCalls(1, probe: probe)

        controller.setRate(2)

        #expect(controller.snapshot.rate == 2)
        #expect(controller.currentPlayerRate == 0)

        await probe.releaseCalls(through: 1)
        let state = try await waitForPlaybackState(in: controller) { $0 == .playing }
        #expect(state == .playing)
        #expect(controller.currentPlayerRate == 2)
    }

    @Test
    func protectedPlaybackPositionRejectsStaleObservationUntilSeekTargetAppears() {
        var protection = PlaybackPositionProtection()

        guard let firstGeneration = protection.startSeek(to: 45) else {
            Issue.record("Expected seek to return a protection generation.")
            return
        }
        let acceptsInitialStalePosition = protection.acceptsObservedPosition(0.2)
        #expect(!acceptsInitialStalePosition)
        #expect(protection.position == 45)

        protection.completeSeek(generation: firstGeneration, finished: true)
        let acceptsStalePositionAfterSeekCompletion = protection.acceptsObservedPosition(0.2)
        #expect(!acceptsStalePositionAfterSeekCompletion)
        let acceptsSettledPosition = protection.acceptsObservedPosition(45.4)
        #expect(acceptsSettledPosition)
        #expect(protection.position == nil)

        guard let oldGeneration = protection.startSeek(to: 30),
              let currentGeneration = protection.startSeek(to: 80)
        else {
            Issue.record("Expected overlapping seeks to return protection generations.")
            return
        }

        protection.completeSeek(generation: oldGeneration, finished: true)
        let acceptsOldSeekTarget = protection.acceptsObservedPosition(30)
        #expect(!acceptsOldSeekTarget)

        protection.completeSeek(generation: currentGeneration, finished: false)
        let acceptsAfterCancelledSeek = protection.acceptsObservedPosition(30)
        #expect(acceptsAfterCancelledSeek)

        _ = protection.startSeek(to: 0)
        let acceptsPreviousPositionAfterZeroSeek = protection.acceptsObservedPosition(60)
        #expect(!acceptsPreviousPositionAfterZeroSeek)
        let acceptsSettledZeroPosition = protection.acceptsObservedPosition(0.2)
        #expect(acceptsSettledZeroPosition)
    }

    @Test
    func protectedPlaybackPositionExpiresAfterTenRejectedTicks() {
        let start = ContinuousClock.now
        var protection = PlaybackPositionProtection()
        _ = protection.startSeek(to: 45, now: start)

        for rejection in 1..<10 {
            let accepted = protection.acceptsObservedPosition(
                0,
                now: start.advanced(by: .milliseconds(rejection * 100))
            )
            #expect(!accepted)
        }

        let acceptedAfterTenRejections = protection.acceptsObservedPosition(
            0,
            now: start.advanced(by: .seconds(1))
        )
        #expect(acceptedAfterTenRejections)
        #expect(protection.position == nil)
    }

    @Test
    func protectedPlaybackPositionExpiresAfterFiveSeconds() {
        let start = ContinuousClock.now
        var protection = PlaybackPositionProtection()
        _ = protection.startSeek(to: 45, now: start)

        let acceptedBeforeExpiry = protection.acceptsObservedPosition(
            0,
            now: start.advanced(by: .milliseconds(4_999))
        )
        #expect(!acceptedBeforeExpiry)
        let acceptedAtExpiry = protection.acceptsObservedPosition(
            0,
            now: start.advanced(by: .seconds(5))
        )
        #expect(acceptedAtExpiry)
    }

    @Test
    func protectedPlaybackPositionStillAcceptsNormalSettleBeforeExpiry() {
        let start = ContinuousClock.now
        var protection = PlaybackPositionProtection()
        _ = protection.startSeek(to: 45, now: start)

        let acceptedStalePosition = protection.acceptsObservedPosition(
            0,
            now: start.advanced(by: .milliseconds(4_900))
        )
        #expect(!acceptedStalePosition)
        let acceptedSettledPosition = protection.acceptsObservedPosition(
            45.4,
            now: start.advanced(by: .milliseconds(4_950))
        )
        #expect(acceptedSettledPosition)
        #expect(protection.position == nil)
    }

    @Test
    func endOfEpisodeRemainingTimeTracksSeekAndRateWithoutWallClockDeadline() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 600))

        let initialNow = Date(timeIntervalSince1970: 1_000)
        controller.setSleepTimer(mode: .endOfEpisode, now: initialNow)

        #expect(controller.sleepTimerMode == .endOfEpisode)
        #expect(controller.sleepTimerEndsAt == nil)
        #expect(controller.sleepTimerRemaining(at: initialNow) == 600)

        controller.seek(to: 120)
        #expect(controller.sleepTimerRemaining(at: initialNow) == 480)

        controller.setRate(2)
        #expect(controller.sleepTimerRemaining(at: initialNow) == 240)
    }

    @Test
    func endOfEpisodeRemainsArmedWhilePausedPastItsInitialEstimate() async throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 0.02))
        controller.setSleepTimer(mode: .endOfEpisode)

        try await Task.sleep(for: .milliseconds(100))

        #expect(controller.sleepTimerMode == .endOfEpisode)
        #expect(controller.sleepTimerRemaining() == 0.02)
    }

    @Test
    func endOfEpisodeRemainsArmedAcrossBufferingAndInterruptionTime() async throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 0.02))
        controller.isAudioSessionActive = true
        controller.play()
        #expect(controller.snapshot.state == .buffering)
        controller.setSleepTimer(mode: .endOfEpisode)
        controller.handleAudioSessionInterruptionBegan()

        try await Task.sleep(for: .milliseconds(100))

        #expect(controller.sleepTimerMode == .endOfEpisode)
        #expect(controller.sleepTimerRemaining() == 0.02)
        controller.handleAudioSessionInterruptionEnded(shouldResume: false)
        #expect(controller.sleepTimerMode == .endOfEpisode)
    }

    @Test
    func fixedDurationTimerStillDrainsWhilePaused() async throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 60))
        controller.setSleepTimer(mode: .duration(0.02))

        try await waitUntil { controller.sleepTimerMode == .off }

        #expect(controller.snapshot.state == .paused)
    }

    @Test
    func naturalEpisodeCompletionClearsEndOfEpisodeTimer() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 60))
        controller.setSleepTimer(mode: .endOfEpisode)

        controller.handleCurrentItemDidPlayToEnd()

        #expect(controller.sleepTimerMode == .off)
        #expect(controller.sleepTimerRemaining() == nil)
    }

    @Test
    func naturalEpisodeCompletionPublishesParkedStateBeforeFinishingCallback() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 60))
        var finishedEpisodeID: EpisodeID?
        var callbackSnapshot: PlaybackSnapshot?
        controller.setEpisodeFinishedHandler { episode in
            finishedEpisodeID = episode.id
            callbackSnapshot = controller.snapshot
        }

        controller.handleCurrentItemDidPlayToEnd()

        #expect(finishedEpisodeID == controller.currentEpisode?.id)
        #expect(callbackSnapshot?.state == .paused)
        #expect(callbackSnapshot?.position == 60)
        #expect(controller.snapshot.state == .paused)
        #expect(controller.snapshot.position == 60)
    }

    @Test
    func endOfEpisodeSleepTimerSuppressesFinishingCallback() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 60))
        controller.setSleepTimer(mode: .endOfEpisode)
        var callbackCount = 0
        controller.setEpisodeFinishedHandler { _ in callbackCount += 1 }

        controller.handleCurrentItemDidPlayToEnd()

        #expect(callbackCount == 0)
        #expect(controller.sleepTimerMode == .off)
        #expect(controller.snapshot.state == .paused)
        #expect(controller.snapshot.position == 60)
    }

    @Test
    func staleItemCompletionIsIgnored() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(id: "current", duration: 60))
        var callbackCount = 0
        controller.setEpisodeFinishedHandler { _ in callbackCount += 1 }
        let staleItem = AVPlayerItem(url: URL(string: "https://example.com/stale.mp3")!)

        controller.handleCurrentItemDidPlayToEnd(staleItem)

        #expect(callbackCount == 0)
        #expect(controller.currentEpisode?.id.rawValue == "current")
        #expect(controller.snapshot.position == 0)
        #expect(controller.snapshot.state == .paused)
    }

    @Test
    func playFromSyntheticEpisodeEndRestartsAtZero() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 60), startPosition: 60)

        controller.play()

        #expect(controller.snapshot.position == 0)
        #expect(controller.snapshot.progressBoundaryID > 0)
    }

    @Test
    func playFromRealFixtureEndRestartsAtZero() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 2
        )
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        let fixtureEpisode = Episode(
            id: EpisodeID(rawValue: "replay-fixture"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Replay Fixture",
            duration: 2,
            audioURL: fixtureURL
        )
        try controller.load(fixtureEpisode, startPosition: 2)

        controller.play()

        #expect(controller.snapshot.position == 0)
        #expect(controller.snapshot.progressBoundaryID > 0)
    }

    @Test
    func nextTrackAdvancesQueueOnlyWhenQueueIsNonempty() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(duration: 120), startPosition: 30)
        var advanceCount = 0
        controller.setNextTrackHandler { advanceCount += 1 }

        controller.handleNextTrackCommand()
        #expect(controller.snapshot.position == 45)
        #expect(advanceCount == 0)

        controller.setHasQueuedNextEpisode(true)
        controller.handleNextTrackCommand()
        #expect(controller.snapshot.position == 45)
        #expect(advanceCount == 1)

        controller.setHasQueuedNextEpisode(false)
        controller.handleNextTrackCommand()
        #expect(controller.snapshot.position == 60)
        #expect(advanceCount == 1)
    }

    @Test
    func remoteRateChangeUsesInstalledPersistenceHandler() {
        let controller = AVFoundationPlaybackController()
        var requestedRate: Float?
        controller.setRemotePlaybackRateChangeHandler { requestedRate = $0 }

        controller.handleRemotePlaybackRateChange(1.5)

        #expect(requestedRate == 1.5)
        #expect(controller.snapshot.rate == 1)
    }

    @Test
    func switchingEpisodesCancelsEndOfEpisodeSleepTimer() throws {
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        try controller.load(episode(id: "first", duration: 600))
        controller.setSleepTimer(mode: .endOfEpisode)
        #expect(controller.sleepTimerMode == .endOfEpisode)

        try controller.load(episode(id: "second", duration: 300))

        #expect(controller.sleepTimerMode == .off)
        #expect(controller.sleepTimerEndsAt == nil)
    }

    @Test
    func autoSkipJumpsPastZoneAndPublishesEvent() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 5
        )
        let controller = AVFoundationPlaybackController()
        let episode = Episode(
            id: EpisodeID(rawValue: "auto-skip-fixture"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Auto Skip Fixture",
            duration: 5,
            audioURL: fixtureURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.setSkipZones([
            PlaybackSkipZone(id: 7, startTime: 0.5, endTime: 2)
        ])
        controller.play()

        let event = try await waitForAutoSkipEvent(in: controller)

        #expect(event == PlaybackAutoSkipEvent(zoneID: 7, sequence: 1))
        #expect(controller.snapshot.position >= 2)
    }

    private func waitForTerminalPlaybackState(
        in controller: AVFoundationPlaybackController
    ) async throws -> PlaybackState {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if case .failed = controller.snapshot.state {
                return controller.snapshot.state
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return controller.snapshot.state
    }

    private func waitForPlaybackState(
        in controller: AVFoundationPlaybackController,
        matching predicate: (PlaybackState) -> Bool
    ) async throws -> PlaybackState {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            let state = controller.snapshot.state
            if predicate(state) {
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return controller.snapshot.state
    }

    private func waitForAutoSkipEvent(
        in controller: AVFoundationPlaybackController
    ) async throws -> PlaybackAutoSkipEvent? {
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if let event = controller.lastAutoSkipEvent {
                return event
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return controller.lastAutoSkipEvent
    }

    private func waitForActivationCalls(
        _ expectedCount: Int,
        probe: AudioSessionActivationProbe
    ) async throws {
        try await waitUntil {
            await probe.recordedCallCount() >= expectedCount
        }
    }

    private func waitUntil(
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for playback test condition.")
    }

    private func playbackEpisode(audioURL: URL) -> Episode {
        Episode(
            id: EpisodeID(rawValue: "activation-fixture"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Activation Fixture",
            duration: 4,
            audioURL: audioURL
        )
    }
}
