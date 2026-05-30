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
}
