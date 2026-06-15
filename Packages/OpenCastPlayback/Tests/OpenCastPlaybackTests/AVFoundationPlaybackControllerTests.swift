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
}
