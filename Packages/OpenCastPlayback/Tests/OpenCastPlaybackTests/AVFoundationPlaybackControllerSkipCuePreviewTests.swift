import Foundation
import OpenCastCore
import Testing
@testable import OpenCastPlayback

/// The settings preview of the skip cue, through the activation and
/// deactivation probes and the factory spy. Every activation call a test
/// starts is released before it ends: a stale preview activation is never
/// cancelled, so an unreleased probe call would spin.
@MainActor
@Suite
struct AVFoundationPlaybackControllerSkipCuePreviewTests {
    private let previewURL = URL(filePath: "/tmp/opencast-skip-cue-preview-a.m4a")
    private let otherPreviewURL = URL(filePath: "/tmp/opencast-skip-cue-preview-b.m4a")
    private let cueURL = URL(filePath: "/tmp/opencast-skip-cue-a.m4a")

    // 10
    @Test("A preview inside a held session takes no activation and makes no release")
    func previewInHeldSessionTakesNothing() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        try controller.load(episode(duration: 240))
        controller.isAudioSessionActive = true

        controller.previewAutoSkipCue(previewURL)

        let preview = try #require(factory.latestCue)
        #expect(factory.requestedURLs == [previewURL])
        #expect(preview.playCount == 1)
        preview.finish()
        await yieldToPendingWork()
        #expect(await activation.recordedCallCount() == 0)
        #expect(await deactivation.recordedCallCount() == 0)
        #expect(controller.isAudioSessionActive)
    }

    // 10
    @Test(
        "Without a held session a preview takes one activation and releases once, after its sound ends",
        arguments: ["episodeLoaded", "nothingLoaded"]
    )
    func previewAcquiresAndReleasesOnce(setup: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 4)
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        if setup == "episodeLoaded" {
            try controller.load(fixtureEpisode(audioURL: fixtureURL, duration: 4))
        }
        let stateBefore = controller.snapshot.state

        controller.previewAutoSkipCue(previewURL)
        #expect(controller.snapshot.state == stateBefore)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        #expect(factory.requestedURLs.isEmpty)

        await activation.releaseCalls(through: 1)
        try await waitUntil { factory.latestCue != nil }
        let preview = try #require(factory.latestCue)
        #expect(preview.playCount == 1)
        #expect(!controller.isAudioSessionActive)
        #expect(controller.snapshot.state == stateBefore)
        #expect(await deactivation.recordedCallCount() == 0)

        preview.finish()
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        controller.unload()
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(await activation.recordedCallCount() == 1)
    }

    // 11
    @Test(
        "An episode that plays during a preview keeps the session, and the preview's end releases nothing",
        arguments: ["whileEpisodeActivates", "afterEpisodeHoldsSession"]
    )
    func episodeTakesOverThePreviewSession(previewEnds: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        let preview = try await startOwnedPreview(controller, factory: factory, activation: activation)

        try controller.load(episode(duration: 240))
        controller.play()
        try await waitUntil { await activation.recordedCallCount() == 2 }
        #expect(preview.isSounding)
        if previewEnds == "whileEpisodeActivates" {
            preview.finish()
        }
        await activation.releaseCalls(through: 2)
        try await waitUntil { controller.isAudioSessionActive }
        if previewEnds == "afterEpisodeHoldsSession" {
            preview.finish()
        }
        await yieldToPendingWork()

        #expect(await deactivation.recordedCallCount() == 0)
        #expect(controller.isAudioSessionActive)
    }

    // 11
    @Test("A load and play right after a preview ends waits for the preview's release")
    func activationAfterAPreviewWaitsForItsRelease() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        let preview = try await startOwnedPreview(controller, factory: factory, activation: activation)

        preview.finish()
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        try controller.load(episode(duration: 240))
        controller.play()
        await yieldToPendingWork()
        #expect(await activation.recordedCallCount() == 1)

        await deactivation.release()
        try await waitUntil { await activation.recordedCallCount() == 2 }
        await activation.releaseCalls(through: 2)
        try await waitUntil { controller.isAudioSessionActive }
        #expect(await deactivation.recordedCallCount() == 1)
    }

    // 11
    @Test(
        "A preview activation that completes after an unload, None or a newer preview plays nothing, with one release in all",
        arguments: ["unload", "none", "newerPreview"]
    )
    func stalePreviewActivationPlaysNothing(invalidation: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        if invalidation == "none" {
            controller.setAutoSkipCue(cueURL)
        }
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }

        switch invalidation {
        case "unload":
            controller.unload()
        case "none":
            controller.setAutoSkipCue(nil)
        default:
            controller.previewAutoSkipCue(otherPreviewURL)
            try await waitUntil { await activation.recordedCallCount() == 2 }
        }
        await activation.releaseCalls(through: 1)

        if invalidation == "newerPreview" {
            await yieldToPendingWork()
            #expect(factory.requestedURLs.isEmpty)
            #expect(await deactivation.recordedCallCount() == 0)
            await activation.releaseCalls(through: 2)
            try await waitUntil { factory.latestCue != nil }
            #expect(factory.requestedURLs == [otherPreviewURL])
            factory.latestCue?.finish()
        } else {
            #expect(factory.requestedURLs.isEmpty)
        }
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()

        #expect(await deactivation.recordedCallCount() == 1)
        #expect(!controller.isAudioSessionActive)
        #expect(factory.requestedURLs == (invalidation == "newerPreview" ? [otherPreviewURL] : []))
    }

    // 11, the known interleaving
    @Test("An episode and a preview activation left stale by an unload release at most twice, in order, before the next activation")
    func staleEpisodeAndPreviewActivationsReleaseInOrder() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        try controller.load(episode(duration: 240))
        controller.play()
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 2 }

        // Released before the unload, so both calls return instead of
        // throwing as cancelled, and both completions run stale.
        await activation.releaseCalls(through: 2)
        controller.unload()
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()

        try controller.load(episode(duration: 240))
        controller.play()
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(await activation.recordedCallCount() == 2)

        await deactivation.releaseCalls(through: 1)
        try await waitUntil { await deactivation.recordedCallCount() == 2 }
        await yieldToPendingWork()
        #expect(await activation.recordedCallCount() == 2)

        await deactivation.release()
        try await waitUntil { await activation.recordedCallCount() == 3 }
        await activation.releaseCalls(through: 3)
        try await waitUntil { controller.isAudioSessionActive }

        #expect(await deactivation.recordedFinishedCountsAtStart() == [0, 1])
        #expect(factory.requestedURLs.isEmpty)
    }

    @Test("An unload that cancels the episode activation taking over a preview's session still releases it once")
    func cancelledTakeoverStillReleasesThePreviewSession() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        let preview = try await startOwnedPreview(controller, factory: factory, activation: activation)

        try controller.load(episode(duration: 240))
        controller.play()
        // The episode's call is never released, so the unload cancels it
        // before it returns and no completion runs for it.
        controller.unload()

        #expect(preview.stopCount == 1)
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(!controller.isAudioSessionActive)
    }

    @Test(
        "An episode activation that fails while taking over a preview's session leaves one release owed",
        arguments: ["previewEndsBeforeTheFailure", "previewEndsAfterTheFailure"]
    )
    func failedTakeoverStillReleasesThePreviewSession(previewEnds: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .failure])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        let preview = try await startOwnedPreview(controller, factory: factory, activation: activation)

        try controller.load(episode(duration: 240))
        controller.play()
        try await waitUntil { await activation.recordedCallCount() == 2 }
        if previewEnds == "previewEndsBeforeTheFailure" {
            preview.finish()
            await yieldToPendingWork()
            // Not released under an episode that is still acquiring.
            #expect(await deactivation.recordedCallCount() == 0)
        }
        await activation.releaseCalls(through: 2)
        try await waitUntil {
            if case .failed = controller.snapshot.state { true } else { false }
        }
        if previewEnds == "previewEndsAfterTheFailure" {
            #expect(await deactivation.recordedCallCount() == 0)
            preview.finish()
        }

        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(!controller.isAudioSessionActive)
    }

    @Test("A second preview while the first sounds plays in the preview's session, and one release follows the second")
    func secondPreviewSharesThePreviewSession() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        let first = try await startOwnedPreview(controller, factory: factory, activation: activation)

        controller.previewAutoSkipCue(otherPreviewURL)

        let second = try #require(factory.latestCue)
        #expect(second !== first)
        #expect(first.stopCount == 1)
        #expect(second.playCount == 1)
        #expect(factory.requestedURLs == [previewURL, otherPreviewURL])
        // A late end of the stopped sound must not end the second.
        first.finish()
        await yieldToPendingWork()
        #expect(second.stopCount == 0)
        #expect(await deactivation.recordedCallCount() == 0)

        second.finish()
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(await activation.recordedCallCount() == 1)
    }

    @Test(
        "An interruption or a reset stops a preview-owned sound and releases nothing; a lost route, an unload or None stops it and releases once",
        arguments: zip(["interruption", "reset", "route", "unload", "none"], [0, 0, 1, 1, 1])
    )
    func sessionEventsStopTheOwnedPreview(event: String, expectedReleases: Int) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        if event == "none" {
            controller.setAutoSkipCue(cueURL)
        }
        let preview = try await startOwnedPreview(controller, factory: factory, activation: activation)

        switch event {
        case "interruption":
            controller.handleAudioSessionInterruptionBegan()
        case "reset":
            controller.handleAudioSessionMediaServicesWereReset()
        case "route":
            controller.handleAudioSessionOldDeviceUnavailable()
        case "unload":
            controller.unload()
        default:
            controller.setAutoSkipCue(nil)
        }

        #expect(preview.stopCount == 1)
        #expect(!preview.isSounding)
        preview.finish()
        if expectedReleases > 0 {
            try await waitUntil { await deactivation.recordedCallCount() == expectedReleases }
        }
        controller.unload()
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == expectedReleases)
        #expect(await activation.recordedCallCount() == 1)
        #expect(!controller.isAudioSessionActive)
    }

    @Test(
        "A preview sounding in an episode's session stops on None, an interruption, a reset, a lost route or an unload, and adds no release",
        arguments: zip(["none", "interruption", "reset", "route", "unload"], [0, 0, 0, 0, 1])
    )
    func sessionEventsStopAPreviewInTheEpisodeSession(event: String, expectedReleases: Int) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        try controller.load(episode(duration: 240))
        controller.isAudioSessionActive = true
        if event == "none" {
            controller.setAutoSkipCue(cueURL)
        }
        controller.play()
        controller.previewAutoSkipCue(previewURL)
        let preview = try #require(factory.latestCue)
        #expect(factory.requestedURLs.last == previewURL)
        #expect(preview.isSounding)

        switch event {
        case "none":
            controller.setAutoSkipCue(nil)
        case "interruption":
            controller.handleAudioSessionInterruptionBegan()
        case "reset":
            // The reset's own replay starts an episode activation.
            controller.handleAudioSessionMediaServicesWereReset()
            try await waitUntil { await activation.recordedCallCount() == 1 }
            await activation.releaseCalls(through: 1)
            try await waitUntil { controller.isAudioSessionActive }
        case "route":
            controller.handleAudioSessionOldDeviceUnavailable()
        default:
            controller.unload()
        }

        #expect(preview.stopCount == 1)
        #expect(!preview.isSounding)
        preview.finish()
        if expectedReleases > 0 {
            try await waitUntil { await deactivation.recordedCallCount() == expectedReleases }
        }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == expectedReleases)
    }

    @Test("A preview whose activation throws plays nothing, releases nothing, leaves playback alone and logs once")
    func failedPreviewActivationLeavesPlaybackAlone() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 4)
        let activation = AudioSessionActivationProbe(outcomes: [.failure])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        try controller.load(fixtureEpisode(audioURL: fixtureURL, duration: 4))

        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        await activation.releaseCalls(through: 1)
        try await waitUntil { messages.contains { $0.hasPrefix("auto-skip cue preview") } }
        await yieldToPendingWork()

        #expect(factory.requestedURLs.isEmpty)
        #expect(controller.snapshot.state == .paused)
        #expect(!controller.isAudioSessionActive)
        #expect(await deactivation.recordedCallCount() == 0)
        #expect(messages.filter { $0.hasPrefix("auto-skip cue preview") } == [
            "auto-skip cue preview could not activate the audio session error=\(AVFoundationPlaybackDiagnosticsFormatter.errorSummary(for: AudioSessionActivationProbe.Failure()))"
        ])
        #expect(!messages.contains { $0.hasPrefix("audio session activation") })
    }

    @Test("With an episode playing, a preview then an unload makes only the unload's release, after the preview stops")
    func previewDuringPlaybackThenUnloadReleasesOnce() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 5)
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        try controller.load(fixtureEpisode(audioURL: fixtureURL, duration: 5))
        controller.play()
        try await waitUntil { await activation.recordedCallCount() == 1 }
        await activation.releaseCalls(through: 1)
        try await waitUntil { controller.snapshot.state == .playing }

        controller.previewAutoSkipCue(previewURL)
        let preview = try #require(factory.latestCue)
        #expect(preview.playCount == 1)
        var sessionHeldAtStop: Bool?
        preview.onStop = { sessionHeldAtStop = controller.isAudioSessionActive }

        controller.unload()

        #expect(preview.stopCount == 1)
        #expect(sessionHeldAtStop == true)
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(await activation.recordedCallCount() == 1)
    }

    @Test(
        "A preview whose activation completes while an episode activates or holds the session plays and owns nothing",
        arguments: ["episodeActivating", "episodeHoldsSession"]
    )
    func previewCompletingBesideAnEpisodeOwnsNothing(episode episodeState: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        try controller.load(episode(duration: 240))
        controller.play()
        try await waitUntil { await activation.recordedCallCount() == 2 }

        if episodeState == "episodeHoldsSession" {
            await activation.releaseCall(at: 1)
            try await waitUntil { controller.isAudioSessionActive }
        }
        await activation.releaseCalls(through: 1)
        try await waitUntil { factory.latestCue != nil }
        let preview = try #require(factory.latestCue)
        #expect(preview.playCount == 1)
        await activation.releaseCalls(through: 2)
        try await waitUntil { controller.isAudioSessionActive }

        preview.finish()
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 0)
        #expect(controller.isAudioSessionActive)
    }

    @Test(
        "A preview left stale while an episode activates or holds the session releases nothing",
        arguments: ["episodeActivating", "episodeHoldsSession"]
    )
    func stalePreviewBesideAnEpisodeReleasesNothing(episode episodeState: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        try controller.load(episode(duration: 240))
        controller.play()
        try await waitUntil { await activation.recordedCallCount() == 2 }
        if episodeState == "episodeHoldsSession" {
            await activation.releaseCall(at: 1)
            try await waitUntil { controller.isAudioSessionActive }
        }

        // A lost route invalidates the preview and leaves the episode's
        // activation running.
        controller.handleAudioSessionOldDeviceUnavailable()
        await activation.releaseCalls(through: 1)
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 0)
        await activation.releaseCalls(through: 2)
        try await waitUntil { controller.isAudioSessionActive }
        await yieldToPendingWork()

        #expect(factory.requestedURLs.isEmpty)
        #expect(await deactivation.recordedCallCount() == 0)
    }

    @Test("A stale preview activation that returns after a newer preview took the session releases nothing")
    func stalePreviewAfterANewerOwnedPreviewReleasesNothing() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        controller.previewAutoSkipCue(otherPreviewURL)
        try await waitUntil { await activation.recordedCallCount() == 2 }

        await activation.releaseCall(at: 1)
        try await waitUntil { factory.latestCue != nil }
        let preview = try #require(factory.latestCue)
        await activation.releaseCalls(through: 1)
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 0)
        #expect(preview.isSounding)

        preview.finish()
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
        #expect(factory.requestedURLs == [otherPreviewURL])
    }

    @Test(
        "A preview whose player cannot be built or does not start releases the session it took at once",
        arguments: ["factoryThrows", "playReturnsFalse"]
    )
    func previewThatCannotSoundReleasesAtOnce(failure: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        await deactivation.release()
        let factory = SkipCuePlayerFactorySpy()
        if failure == "factoryThrows" {
            factory.failure = SkipCuePlayerFactorySpy.Failure()
        } else {
            factory.playResult = false
        }
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }

        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        await activation.releaseCalls(through: 1)
        try await waitUntil { await deactivation.recordedCallCount() == 1 }
        controller.unload()
        await yieldToPendingWork()

        #expect(factory.requestedURLs == [previewURL])
        #expect(factory.latestCue?.isSounding != true)
        #expect(await deactivation.recordedCallCount() == 1)
    }

    @Test("A preview right after an unload waits for the unload's release before it activates")
    func previewAfterAnUnloadWaitsForItsRelease() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success])
        let deactivation = AudioSessionDeactivationProbe()
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: activation, deactivation: deactivation)
        defer { controller.unload() }
        try controller.load(episode(duration: 240))
        controller.isAudioSessionActive = true
        controller.unload()
        try await waitUntil { await deactivation.recordedCallCount() == 1 }

        controller.previewAutoSkipCue(previewURL)
        await yieldToPendingWork()
        #expect(await activation.recordedCallCount() == 0)

        await deactivation.release()
        try await waitUntil { await activation.recordedCallCount() == 1 }
        await activation.releaseCalls(through: 1)
        try await waitUntil { factory.latestCue != nil }
        factory.latestCue?.finish()
        try await waitUntil { await deactivation.recordedCallCount() == 2 }
    }

    /// Previews `previewURL` with nothing holding the session and returns
    /// the sounding player once the preview owns the session.
    private func startOwnedPreview(
        _ controller: AVFoundationPlaybackController,
        factory: SkipCuePlayerFactorySpy,
        activation: AudioSessionActivationProbe
    ) async throws -> SkipCuePlayerSpy {
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 1 }
        await activation.releaseCalls(through: 1)
        try await waitUntil { factory.latestCue != nil }
        let preview = try #require(factory.latestCue)
        #expect(preview.isSounding)
        #expect(!controller.isAudioSessionActive)
        return preview
    }

    private func makeController(
        factory: SkipCuePlayerFactorySpy,
        activation: AudioSessionActivationProbe,
        deactivation: AudioSessionDeactivationProbe
    ) -> AVFoundationPlaybackController {
        AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await activation.activate() },
            audioSessionDeactivation: { await deactivation.deactivate() },
            skipCuePlayerFactory: { try factory.make($0) }
        )
    }

    /// Lets tasks already queued on the main actor and the probes run, so
    /// an absent call is absent and not merely late.
    private func yieldToPendingWork() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// The event-log line without its timestamp, episode, source, position
    /// and duration fields.
    private static func eventLogMessage(_ line: String) -> String {
        String(line.split(separator: " ", maxSplits: 5)[5])
    }

    private func writeFixture(duration: TimeInterval) throws -> URL {
        try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: duration
        )
    }

    private func fixtureEpisode(audioURL: URL, duration: TimeInterval) -> Episode {
        Episode(
            id: EpisodeID(rawValue: "skip-cue-preview-fixture"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Skip Cue Preview Fixture",
            duration: duration,
            audioURL: audioURL
        )
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(60)
        while Date.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for playback test condition.")
    }
}
