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

        try controller.load(episode)
        controller.play()

        let failedState = try await waitForTerminalPlaybackState(in: controller)
        guard case .failed = failedState else {
            Issue.record("Expected failed playback state before retry, got \(failedState).")
            return
        }

        try Data(contentsOf: validFixtureURL).write(to: fileURL, options: .atomic)
        controller.play()

        let recoveredState = try await waitForPlaybackState(in: controller) { state in
            state == .playing
        }
        #expect(recoveredState == .playing)
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
