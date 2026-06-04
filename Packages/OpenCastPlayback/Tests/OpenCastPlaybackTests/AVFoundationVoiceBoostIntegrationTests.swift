import Foundation
import OpenCastCore
import OpenCastVoiceBoost
import Testing
@testable import OpenCastPlayback

struct AVFoundationVoiceBoostIntegrationTests {
    private let remoteVoiceBoostTestFlag = "OPENCAST_RUN_REMOTE_VOICEBOOST_TESTS"
    private let mp3VoiceBoostTestFlag = "OPENCAST_RUN_MP3_VOICEBOOST_TESTS"
    private let remoteFeedURLOverrideKey = "OPENCAST_VOICEBOOST_REMOTE_FEED_URL"
    private let libriVoxFeedURL = URL(string: "https://feeds.feedburner.com/LibrivoxCommunityPodcast")!

    private enum InjectedVoiceBoostTapError: Error {
        case failed
    }

    @Test
    @MainActor
    func controllerProcessesCompressedEpisodeThroughVoiceBoostTap() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings()
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-compressed-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Compressed Fixture",
            duration: 1.5,
            audioURL: fixtureURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()

        let deadline = Date.now.addingTimeInterval(5)
        while diagnostics.snapshot.processedFrameCount == 0 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let snapshot = diagnostics.snapshot
        #expect(snapshot.prepareCount > 0)
        #expect(snapshot.processCount > 0)
        #expect(snapshot.processedFrameCount > 0)
        #expect(snapshot.sourceErrorCount == 0)
        #expect(snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerProcessesMP3EpisodeThroughVoiceBoostTap() async throws {
        guard ProcessInfo.processInfo.environment[mp3VoiceBoostTestFlag] == "1" else {
            return
        }

        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeGeneratedMP3Sine()
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-mp3-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "MP3 Fixture",
            duration: 1,
            audioURL: fixtureURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()

        let processedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        #expect(processedFrameCount > 0)
        #expect(diagnostics.snapshot.prepareCount > 0)
        #expect(diagnostics.snapshot.processCount > 0)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerFallsBackToDryPlaybackWhenVoiceBoostTapCreationFails() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: diagnostics,
            voiceBoostAudioTapFactory: { _, _ in
                throw InjectedVoiceBoostTapError.failed
            }
        )
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-dry-fallback-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Dry Fallback Fixture",
            duration: 4,
            audioURL: fixtureURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let position = try await waitForPosition(in: controller, exceeding: 0)

        #expect(position > 0)
        #expect(controller.snapshot.state == .playing)
        #expect(diagnostics.snapshot.prepareCount == 0)
        #expect(diagnostics.snapshot.processCount == 0)
    }

    @Test
    @MainActor
    func controllerProcessesRemoteCompressedEpisodeThroughVoiceBoostTap() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings()
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-compressed-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Compressed Fixture",
            duration: 1.5,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()

        let deadline = Date.now.addingTimeInterval(5)
        while diagnostics.snapshot.processedFrameCount == 0 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let snapshot = diagnostics.snapshot
        #expect(snapshot.prepareCount > 0)
        #expect(snapshot.processCount > 0)
        #expect(snapshot.processedFrameCount > 0)
        #expect(snapshot.sourceErrorCount == 0)
        #expect(snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerContinuesRemoteVoiceBoostProcessingAfterSeekAndRateChange() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-seek-rate-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-seek-rate-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Seek Rate Fixture",
            duration: 4,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let firstProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        controller.seek(to: 1)
        controller.setRate(1.5)
        let secondProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: firstProcessedFrameCount
        )

        #expect(controller.snapshot.rate == 1.5)
        #expect(controller.snapshot.position >= 1)
        #expect(secondProcessedFrameCount > firstProcessedFrameCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerCanToggleRemoteVoiceBoostWhilePlaying() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 12
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-toggle-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-toggle-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Toggle Fixture",
            duration: 12,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let enabledProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        controller.setVoiceBoostEnabled(false)
        let disabledBypassedFrameCount = try await waitForBypassedFrames(
            in: diagnostics,
            exceeding: 0
        )

        controller.setVoiceBoostEnabled(true)
        let reenabledProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: enabledProcessedFrameCount
        )

        #expect(controller.snapshot.state == .playing)
        #expect(disabledBypassedFrameCount > 0)
        #expect(reenabledProcessedFrameCount > enabledProcessedFrameCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerSurvivesRapidRemoteVoiceBoostConfigurationUpdatesWhilePlaying() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 12
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-rapid-update-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-rapid-update-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Rapid Update Fixture",
            duration: 12,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let initialProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        for updateIndex in 0..<24 {
            var configuration = VoiceBoostConfiguration.default
            configuration.isEnabled = updateIndex % 3 != 1
            configuration.targetLUFS = -13 + Double(updateIndex % 3)
            controller.updateVoiceBoostConfiguration(configuration)
            try await Task.sleep(for: .milliseconds(20))
        }

        controller.updateVoiceBoostConfiguration(.default)
        let finalProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: initialProcessedFrameCount
        )

        #expect(controller.snapshot.state == .playing)
        #expect(finalProcessedFrameCount > initialProcessedFrameCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerCanEnableRemoteVoiceBoostAfterStartingDryPlayback() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 12
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-enable-after-dry-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-enable-after-dry-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Enable After Dry Fixture",
            duration: 12,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        controller.setVoiceBoostEnabled(false)
        try controller.load(episode)
        controller.play()
        let dryPosition = try await waitForPosition(in: controller, exceeding: 0)

        controller.setVoiceBoostEnabled(true)
        let tapInstallAttemptCount = try await waitForTapInstallAttempts(in: diagnostics, atLeast: 2)
        let processedFrameCount = try await waitForProcessedFrames(in: diagnostics, exceeding: 0)

        #expect(dryPosition > 0)
        #expect(tapInstallAttemptCount >= 2)
        #expect(processedFrameCount > 0)
        #expect(controller.snapshot.state == .playing)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerContinuesRemoteVoiceBoostProcessingAfterPauseResumeAndSkip() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 8
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-pause-resume-skip-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-pause-resume-skip-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Pause Resume Skip Fixture",
            duration: 8,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let firstProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        controller.pause()
        controller.skip(by: 2)
        controller.play()
        let secondProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: firstProcessedFrameCount
        )

        #expect(controller.snapshot.state == .playing)
        #expect(controller.snapshot.position >= 2)
        #expect(secondProcessedFrameCount > firstProcessedFrameCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func sleepTimerPausesRemotePlaybackWhileVoiceBoostTapIsActive() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-sleep-timer-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-sleep-timer-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Sleep Timer Fixture",
            duration: 4,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let processedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        controller.setSleepTimer(duration: 0.2)
        let snapshot = try await waitForPaused(controller)

        #expect(processedFrameCount > 0)
        #expect(snapshot.state == .paused)
        #expect(snapshot.sleepTimerEndsAt == nil)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func cancelledSleepTimerKeepsRemoteVoiceBoostPlaybackActive() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-cancelled-sleep-timer-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-cancelled-sleep-timer-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Cancelled Sleep Timer Fixture",
            duration: 4,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let firstProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )

        controller.setSleepTimer(duration: 0.3)
        #expect(controller.snapshot.sleepTimerEndsAt != nil)

        controller.setSleepTimer(duration: nil)
        try await Task.sleep(for: .milliseconds(450))
        let secondProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: firstProcessedFrameCount
        )

        #expect(controller.snapshot.state == .playing)
        #expect(controller.snapshot.sleepTimerEndsAt == nil)
        #expect(secondProcessedFrameCount > firstProcessedFrameCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func controllerFinishesRemoteVoiceBoostPlaybackAtEpisodeEnd() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let duration = 1.2
        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: duration
        )
        let server = try HTTPFixtureServer(
            data: try Data(contentsOf: fixtureURL),
            fileName: "voiceboost-episode-end-fixture.m4a",
            contentType: "audio/mp4"
        )
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        let episode = Episode(
            id: EpisodeID(rawValue: "voiceboost-remote-episode-end-fixture"),
            podcastID: PodcastID(rawValue: "https://example.com/voiceboost.xml"),
            podcastTitle: "Voice Boost Fixture",
            title: "Remote Episode End Fixture",
            duration: duration,
            audioURL: server.url
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        try controller.load(episode)
        controller.play()
        let processedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0
        )
        let snapshot = try await waitForEnded(controller, minimumPosition: duration * 0.75)

        #expect(processedFrameCount > 0)
        #expect(snapshot.state == .paused)
        #expect(snapshot.position >= duration * 0.75)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func optInRemotePodcastEpisodeProcessesThroughVoiceBoostTap() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[remoteVoiceBoostTestFlag] == "1" else {
            return
        }

        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let episode = try await firstRemotePodcastEpisode(environment: environment)
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        defer {
            controller.unload()
        }

        try controller.load(episode)
        controller.play()
        let processedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0,
            timeout: 30
        )

        #expect(processedFrameCount > 0)
        #expect(controller.snapshot.state == .playing)
        #expect(diagnostics.snapshot.prepareCount > 0)
        #expect(diagnostics.snapshot.processCount > 0)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    @Test
    @MainActor
    func optInRemotePodcastEpisodeSurvivesVoiceBoostControls() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[remoteVoiceBoostTestFlag] == "1" else {
            return
        }

        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let episode = try await firstRemotePodcastEpisode(environment: environment)
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(voiceBoostTapDiagnostics: diagnostics)
        defer {
            controller.unload()
        }

        try controller.load(episode)
        controller.play()
        let initialProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: 0,
            timeout: 30
        )

        controller.pause()
        let pausedSnapshot = try await waitForPaused(controller)

        controller.play()
        let resumedProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: initialProcessedFrameCount,
            timeout: 30
        )

        let seekPosition = remoteSeekPosition(for: episode)
        controller.seek(to: seekPosition)
        controller.setRate(1.25)
        let seekProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: resumedProcessedFrameCount,
            timeout: 30
        )

        controller.skip(by: 5)
        let skipProcessedFrameCount = try await waitForProcessedFrames(
            in: diagnostics,
            exceeding: seekProcessedFrameCount,
            timeout: 30
        )

        #expect(pausedSnapshot.state == .paused)
        #expect(controller.snapshot.state == .playing)
        #expect(controller.snapshot.rate == 1.25)
        #expect(controller.snapshot.position >= seekPosition)
        #expect(resumedProcessedFrameCount > initialProcessedFrameCount)
        #expect(seekProcessedFrameCount > resumedProcessedFrameCount)
        #expect(skipProcessedFrameCount > seekProcessedFrameCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)
    }

    private func firstRemotePodcastEpisode(environment: [String: String]) async throws -> Episode {
        let feedURL = environment[remoteFeedURLOverrideKey]
            .flatMap(URL.init(string:)) ?? libriVoxFeedURL
        let feed = try await DefaultFeedService().fetchFeed(at: feedURL)
        return try #require(feed.episodes.first { $0.audioURL != nil })
    }

    private func remoteSeekPosition(for episode: Episode) -> TimeInterval {
        guard let duration = episode.duration, duration.isFinite, duration > 120 else {
            return 30
        }
        return min(60, duration * 0.25)
    }

    @MainActor
    private func waitForProcessedFrames(
        in diagnostics: VoiceBoostAudioTapDiagnostics,
        exceeding minimumFrameCount: Int,
        timeout: TimeInterval = 5
    ) async throws -> Int {
        let deadline = Date.now.addingTimeInterval(timeout)
        while diagnostics.snapshot.processedFrameCount <= minimumFrameCount && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let processedFrameCount = diagnostics.snapshot.processedFrameCount
        if processedFrameCount <= minimumFrameCount {
            Issue.record("Timed out waiting for processed frames to exceed \(minimumFrameCount).")
        }
        return processedFrameCount
    }

    @MainActor
    private func waitForBypassedFrames(
        in diagnostics: VoiceBoostAudioTapDiagnostics,
        exceeding minimumFrameCount: Int
    ) async throws -> Int {
        let deadline = Date.now.addingTimeInterval(5)
        while diagnostics.snapshot.bypassedFrameCount <= minimumFrameCount && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let bypassedFrameCount = diagnostics.snapshot.bypassedFrameCount
        if bypassedFrameCount <= minimumFrameCount {
            Issue.record("Timed out waiting for bypassed frames to exceed \(minimumFrameCount).")
        }
        return bypassedFrameCount
    }

    @MainActor
    private func waitForTapInstallAttempts(
        in diagnostics: VoiceBoostAudioTapDiagnostics,
        atLeast minimumAttemptCount: Int
    ) async throws -> Int {
        let deadline = Date.now.addingTimeInterval(5)
        while diagnostics.snapshot.tapInstallAttemptCount < minimumAttemptCount && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let tapInstallAttemptCount = diagnostics.snapshot.tapInstallAttemptCount
        if tapInstallAttemptCount < minimumAttemptCount {
            Issue.record("Timed out waiting for at least \(minimumAttemptCount) tap install attempts.")
        }
        return tapInstallAttemptCount
    }

    @MainActor
    private func waitForPosition(
        in controller: AVFoundationPlaybackController,
        exceeding minimumPosition: TimeInterval
    ) async throws -> TimeInterval {
        let deadline = Date.now.addingTimeInterval(5)
        while controller.snapshot.position <= minimumPosition && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let position = controller.snapshot.position
        if position <= minimumPosition {
            Issue.record("Timed out waiting for playback position to exceed \(minimumPosition).")
        }
        return position
    }

    @MainActor
    private func waitForEnded(
        _ controller: AVFoundationPlaybackController,
        minimumPosition: TimeInterval
    ) async throws -> PlaybackSnapshot {
        let deadline = Date.now.addingTimeInterval(5)
        while (controller.snapshot.state != .paused || controller.snapshot.position < minimumPosition)
            && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let snapshot = controller.snapshot
        if snapshot.state != .paused || snapshot.position < minimumPosition {
            Issue.record("Timed out waiting for playback to end at or beyond \(minimumPosition).")
        }
        return snapshot
    }

    @MainActor
    private func waitForPaused(_ controller: AVFoundationPlaybackController) async throws -> PlaybackSnapshot {
        let deadline = Date.now.addingTimeInterval(5)
        while controller.snapshot.state != .paused && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let snapshot = controller.snapshot
        if snapshot.state != .paused {
            Issue.record("Timed out waiting for playback to pause.")
        }
        return snapshot
    }
}
