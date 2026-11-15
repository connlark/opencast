import Foundation
import OpenCastCore
import Testing
@testable import OpenCastPlayback

/// The skip cue through the factory seam. Tests on `episode(duration:)`
/// (remote audio that never loads here) run without yielding after setup,
/// so no player callback can interleave; tests that need a real seek or a
/// real tick play a local fixture.
@MainActor
@Suite
struct AVFoundationPlaybackControllerSkipCueTests {
    private let cueURL = URL(filePath: "/tmp/opencast-skip-cue-a.m4a")
    private let otherCueURL = URL(filePath: "/tmp/opencast-skip-cue-b.m4a")

    // 1
    @Test("A tick into a zone while playing plays the cue once")
    func tickIntoZoneWhilePlayingPlaysOnce() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 5)
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: probe)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        controller.setAutoSkipCue(cueURL)
        try controller.load(fixtureEpisode(audioURL: fixtureURL, duration: 5))
        controller.setSkipZones([PlaybackSkipZone(id: 7, startTime: 0.5, endTime: 2)])

        controller.play()
        await probe.releaseCalls(through: 1)
        try await waitUntil { controller.lastAutoSkipEvent != nil }

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 7, sequence: 1))
        #expect(factory.requestedURLs == [cueURL])
        #expect(factory.latestCue?.playCount == 1)
        #expect(skipMessages(in: messages).count == 1)
        #expect(skipMessages(in: messages).first?.hasSuffix(" cue=played") == true)
    }

    // 2
    @Test(
        "While playback is not requested the skip happens and the cue stays silent",
        arguments: zip(["zonesAtStart", "restore", "skipButton"], ["0.000", "3.000", "2.500"])
    )
    func skipWhileNotRequestedStaysSilent(landing: String, from: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 8)
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        controller.isAudioSessionActive = true
        controller.setAutoSkipCue(cueURL)
        let fixture = fixtureEpisode(audioURL: fixtureURL, duration: 8)

        switch landing {
        case "zonesAtStart":
            try controller.load(fixture)
            controller.setSkipZones([PlaybackSkipZone(id: 3, startTime: 0, endTime: 4)])
        case "restore":
            try controller.load(fixture, startPosition: 3)
            controller.setSkipZones([PlaybackSkipZone(id: 3, startTime: 2, endTime: 4)])
        default:
            try controller.load(fixture)
            controller.setSkipZones([PlaybackSkipZone(id: 3, startTime: 2, endTime: 4)])
            #expect(controller.lastAutoSkipEvent == nil)
            controller.skip(by: 2.5)
        }
        try await waitUntil { controller.lastAutoSkipEvent != nil }

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 3, sequence: 1))
        #expect(factory.requestedURLs == [cueURL])
        #expect(factory.latestCue?.playCount == 0)
        #expect(skipMessages(in: messages) == ["auto-skip zone=3 from=\(from) to=4.000 cue=none(paused)"])
    }

    // 3
    @Test(
        "Auto-Skip switched on inside a zone, and replay from the end into a zone, play while playing",
        arguments: ["enable", "replay"]
    )
    func enableAndReplayWhilePlayingPlayOnce(entry: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = entry == "replay" ? try writeFixture(duration: 4) : nil
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory)
        defer {
            controller.unload()
            if let fixtureURL {
                try? FileManager.default.removeItem(at: fixtureURL)
            }
        }
        controller.isAudioSessionActive = true
        controller.setAutoSkipCue(cueURL)

        if let fixtureURL {
            try controller.load(fixtureEpisode(audioURL: fixtureURL, duration: 4), startPosition: 4)
            controller.setSkipZones([PlaybackSkipZone(id: 4, startTime: 0, endTime: 1.5)])
            #expect(controller.lastAutoSkipEvent == nil)
            controller.play()
            try await waitUntil { controller.lastAutoSkipEvent != nil }
        } else {
            controller.setAutoSkipEnabled(false)
            try controller.load(episode(duration: 240), startPosition: 30)
            controller.setSkipZones([PlaybackSkipZone(id: 4, startTime: 25, endTime: 40)])
            controller.play()
            #expect(controller.lastAutoSkipEvent == nil)
            controller.setAutoSkipEnabled(true)
        }

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 4, sequence: 1))
        #expect(factory.latestCue?.playCount == 1)
    }

    // 4
    @Test(
        "A skip that ends the episode stays silent; one with an unknown duration plays",
        arguments: zip(
            ["outro", "clampedToDuration", "unknownDuration"],
            [
                "auto-skip zone=7 from=80.000 reached outro=90.000 cue=none(ending)",
                "auto-skip zone=7 from=90.000 to=100.000 cue=none(ending)",
                "auto-skip zone=7 from=80.000 to=95.000 cue=played"
            ]
        )
    )
    func endingSkipsStaySilent(ending: String, expectedMessage: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory)
        defer { controller.unload() }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        let duration: TimeInterval? = ending == "unknownDuration" ? nil : 100
        let zone = ending == "clampedToDuration"
            ? PlaybackSkipZone(id: 7, startTime: 90, endTime: 120)
            : PlaybackSkipZone(id: 7, startTime: 80, endTime: 95)
        let boundaries = ending == "outro"
            ? PlaybackEpisodeBoundaries(skipOutroSeconds: 10)
            : .disabled
        try startPlaying(controller, episode: episode(duration: duration), boundaries: boundaries)
        controller.setSkipZones([zone])

        controller.handleObservedPlaybackPosition(zone.startTime - 1, duration: duration)
        controller.handleObservedPlaybackPosition(zone.startTime, duration: duration)

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 7, sequence: 1))
        #expect(factory.latestCue?.playCount == (ending == "unknownDuration" ? 1 : 0))
        #expect(skipMessages(in: messages) == [expectedMessage])
    }

    // 5
    @Test("A skip-button landing inside a zone while playing plays the cue once")
    func skipButtonLandingWhilePlayingPlaysOnce() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 10)
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        try startPlaying(controller, episode: fixtureEpisode(audioURL: fixtureURL, duration: 10))
        controller.setSkipZones([PlaybackSkipZone(id: 5, startTime: 5, endTime: 8)])

        controller.skip(by: 6)
        try await waitUntil { controller.lastAutoSkipEvent != nil }

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 5, sequence: 1))
        #expect(factory.latestCue?.playCount == 1)
        #expect(skipMessages(in: messages) == ["auto-skip zone=5 from=6.000 to=8.000 cue=played"])
    }

    // 6
    @Test("A skip while the cue is still sounding does not start it again")
    func skipWhileSoundingPlaysOnce() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory)
        defer { controller.unload() }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        try startPlaying(controller, episode: episode(duration: 240))
        controller.setSkipZones([
            PlaybackSkipZone(id: 1, startTime: 30, endTime: 40),
            PlaybackSkipZone(id: 2, startTime: 60, endTime: 70),
            PlaybackSkipZone(id: 3, startTime: 100, endTime: 110)
        ])
        let cue = try #require(factory.latestCue)

        tick(controller, through: [29, 30, 40, 59, 60])
        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 2, sequence: 2))
        #expect(cue.playCount == 1)

        cue.finish()
        tick(controller, through: [70, 99, 100])

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 3, sequence: 3))
        #expect(cue.playCount == 2)
        #expect(skipMessages(in: messages) == [
            "auto-skip zone=1 from=30.000 to=40.000 cue=played",
            "auto-skip zone=2 from=60.000 to=70.000 cue=none(busy)",
            "auto-skip zone=3 from=100.000 to=110.000 cue=played"
        ])
    }

    // 7
    @Test("With no cue set the factory is never called and both skip messages read as before")
    func noCueLeavesMessagesAsBefore() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: probe)
        defer { controller.unload() }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        controller.setAutoSkipCue(nil)
        try controller.load(
            episode(duration: 100),
            boundaries: PlaybackEpisodeBoundaries(skipOutroSeconds: 10)
        )
        controller.setSkipZones([
            PlaybackSkipZone(id: 1, startTime: 30, endTime: 40),
            PlaybackSkipZone(id: 2, startTime: 80, endTime: 95)
        ])
        controller.play()
        await probe.releaseCalls(through: 1)
        try await waitUntil { controller.isAudioSessionActive }

        tick(controller, through: [29, 30, 40, 79, 80])

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 2, sequence: 2))
        #expect(factory.requestedURLs.isEmpty)
        #expect(!controller.hasAutoSkipCueForTesting)
        // Copied from the controller before the cue existed.
        #expect(skipMessages(in: messages) == [
            "auto-skip zone=1 from=30.000 to=40.000",
            "auto-skip zone=2 from=80.000 reached outro=90.000"
        ])
    }

    // 8
    @Test("A cue set before load is opened only when the activation completes, once per URL")
    func cueOpensOnlyInsideTheActivatedSession() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: probe)
        defer { controller.unload() }

        controller.setAutoSkipCue(cueURL)
        controller.setAutoSkipCue(cueURL)
        try controller.load(episode(duration: 240))
        controller.play()
        try await waitUntil { await probe.recordedCallCount() == 1 }
        #expect(factory.requestedURLs.isEmpty)
        #expect(!controller.hasAutoSkipCueForTesting)

        await probe.releaseCalls(through: 1)
        try await waitUntil { controller.isAudioSessionActive }
        #expect(factory.requestedURLs == [cueURL])
        #expect(controller.hasAutoSkipCueForTesting)

        controller.setAutoSkipCue(cueURL)
        #expect(factory.requestedURLs == [cueURL])

        controller.setAutoSkipCue(otherCueURL)
        #expect(factory.requestedURLs == [cueURL, otherCueURL])
        #expect(factory.cues.first?.stopCount == 1)
        #expect(factory.cues.count == 2)
    }

    // 8
    @Test("A cue that cannot be opened leaves playback alone and logs one message")
    func failedCueLeavesPlaybackAlone() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fixtureURL = try writeFixture(duration: 5)
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let factory = SkipCuePlayerFactorySpy()
        factory.failure = SkipCuePlayerFactorySpy.Failure()
        let controller = makeController(factory: factory, activation: probe)
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        controller.setAutoSkipCue(cueURL)
        try controller.load(fixtureEpisode(audioURL: fixtureURL, duration: 5))
        controller.setSkipZones([PlaybackSkipZone(id: 7, startTime: 0.5, endTime: 2)])

        controller.play()
        await probe.releaseCalls(through: 1)
        try await waitUntil { controller.snapshot.state == .playing }
        try await waitUntil { controller.lastAutoSkipEvent != nil }

        #expect(controller.isAudioSessionActive)
        #expect(!controller.hasAutoSkipCueForTesting)
        #expect(factory.requestedURLs == [cueURL])
        #expect(messages.filter { $0.hasPrefix("auto-skip cue unavailable error=") }.count == 1)
        #expect(skipMessages(in: messages).first?.hasSuffix(" cue=none(failed)") == true)
    }

    @Test("A cue that does not start is logged as failed and does not count as sounding")
    func cueThatDoesNotStartIsFailed() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let factory = SkipCuePlayerFactorySpy()
        factory.playResult = false
        let controller = makeController(factory: factory)
        defer { controller.unload() }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        try startPlaying(controller, episode: episode(duration: 240))
        controller.setSkipZones([
            PlaybackSkipZone(id: 1, startTime: 30, endTime: 40),
            PlaybackSkipZone(id: 2, startTime: 60, endTime: 70)
        ])

        tick(controller, through: [29, 30, 40, 59, 60])

        #expect(factory.latestCue?.playCount == 2)
        #expect(factory.latestCue?.isSounding == false)
        #expect(skipMessages(in: messages) == [
            "auto-skip zone=1 from=30.000 to=40.000 cue=none(failed)",
            "auto-skip zone=2 from=60.000 to=70.000 cue=none(failed)"
        ])
    }

    @Test("A skip while the session is still activating stays silent")
    func skipBeforeTheSessionIsHeldStaysSilent() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let probe = AudioSessionActivationProbe(outcomes: [.success])
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory, activation: probe)
        defer { controller.unload() }
        var messages: [String] = []
        controller.setEventLogHandler { messages.append(Self.eventLogMessage($0)) }
        controller.setAutoSkipCue(cueURL)
        try controller.load(episode(duration: 240))
        controller.play()

        controller.setSkipZones([PlaybackSkipZone(id: 1, startTime: 0, endTime: 10)])

        #expect(controller.lastAutoSkipEvent == PlaybackAutoSkipEvent(zoneID: 1, sequence: 1))
        #expect(factory.requestedURLs.isEmpty)
        #expect(skipMessages(in: messages) == ["auto-skip zone=1 from=0.000 to=10.000 cue=none(inactive)"])
    }

    // 9
    @Test(
        "Interruption, a lost route, None, a media-services reset and unload each stop or drop a sounding cue",
        arguments: ["interruption", "route", "none", "reset", "unload"]
    )
    func soundingCueStopsOrDrops(event: String) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activationProbe = AudioSessionActivationProbe(outcomes: [.success])
        let deactivationProbe = AudioSessionDeactivationProbe()
        await deactivationProbe.release()
        let factory = SkipCuePlayerFactorySpy()
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await activationProbe.activate() },
            audioSessionDeactivation: { await deactivationProbe.deactivate() },
            skipCuePlayerFactory: { try factory.make($0) }
        )
        defer { controller.unload() }
        try startPlaying(controller, episode: episode(duration: 240))
        controller.setSkipZones([PlaybackSkipZone(id: 1, startTime: 30, endTime: 40)])
        tick(controller, through: [29, 30])
        let cue = try #require(factory.latestCue)
        #expect(cue.isSounding)
        var sessionHeldAtStop: Bool?
        cue.onStop = { sessionHeldAtStop = controller.isAudioSessionActive }

        switch event {
        case "interruption":
            controller.handleAudioSessionInterruptionBegan()
        case "route":
            controller.handleAudioSessionOldDeviceUnavailable()
        case "none":
            controller.setAutoSkipCue(nil)
        case "reset":
            controller.handleAudioSessionMediaServicesWereReset()
        default:
            controller.unload()
        }

        #expect(cue.stopCount == 1)
        #expect(!cue.isSounding)
        #expect(controller.hasAutoSkipCueForTesting == (event == "route"))
        switch event {
        case "none":
            #expect(sessionHeldAtStop == true)
            #expect(factory.requestedURLs == [cueURL])
        case "reset":
            // The reset's own reactivation opens the next cue.
            try await waitUntil { await activationProbe.recordedCallCount() == 1 }
            #expect(factory.requestedURLs == [cueURL])
            await activationProbe.releaseCalls(through: 1)
            try await waitUntil { controller.isAudioSessionActive }
            #expect(factory.requestedURLs == [cueURL, cueURL])
            #expect(controller.hasAutoSkipCueForTesting)
        case "unload":
            #expect(sessionHeldAtStop == true)
            try await waitUntil { await deactivationProbe.recordedCallCount() == 1 }
        default:
            break
        }
    }

    @Test(
        "Loading another episode stops a sounding cue and leaves a silent one alone",
        arguments: [true, false]
    )
    func loadSilencesASoundingCue(isSounding: Bool) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let factory = SkipCuePlayerFactorySpy()
        let controller = makeController(factory: factory)
        defer { controller.unload() }
        try startPlaying(controller, episode: episode(duration: 240))
        let cue = try #require(factory.latestCue)
        if isSounding {
            controller.setSkipZones([PlaybackSkipZone(id: 1, startTime: 30, endTime: 40)])
            tick(controller, through: [29, 30])
            #expect(cue.isSounding)
        }

        try controller.load(episode(id: "next", duration: 240))

        #expect(cue.stopCount == (isSounding ? 1 : 0))
        #expect(!cue.isSounding)
        #expect(controller.hasAutoSkipCueForTesting)
        #expect(factory.requestedURLs == [cueURL])
    }

    private func makeController(
        factory: SkipCuePlayerFactorySpy,
        activation probe: AudioSessionActivationProbe? = nil
    ) -> AVFoundationPlaybackController {
        guard let probe else {
            return AVFoundationPlaybackController(
                voiceBoostTapDiagnostics: nil,
                skipCuePlayerFactory: { try factory.make($0) }
            )
        }
        return AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await probe.activate() },
            skipCuePlayerFactory: { try factory.make($0) }
        )
    }

    /// Marks the session held, so `setAutoSkipCue` opens the cue at once, then
    /// requests playback.
    private func startPlaying(
        _ controller: AVFoundationPlaybackController,
        episode current: Episode,
        boundaries: PlaybackEpisodeBoundaries = .disabled
    ) throws {
        try controller.load(current, boundaries: boundaries)
        controller.isAudioSessionActive = true
        controller.setAutoSkipCue(cueURL)
        controller.play()
    }

    private func tick(_ controller: AVFoundationPlaybackController, through positions: [TimeInterval]) {
        for position in positions {
            controller.handleObservedPlaybackPosition(position, duration: controller.duration)
        }
    }

    private func skipMessages(in messages: [String]) -> [String] {
        messages.filter { $0.hasPrefix("auto-skip zone=") }
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
            id: EpisodeID(rawValue: "skip-cue-fixture"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Skip Cue Fixture",
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
