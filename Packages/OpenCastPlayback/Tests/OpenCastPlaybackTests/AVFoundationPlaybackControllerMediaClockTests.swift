import AVFoundation
import Foundation
import OpenCastCore
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct AVFoundationPlaybackControllerMediaClockTests {
    @Test
    func subscriptionInstallsAndCancellationRemovesObserver() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }
        #expect(controller.mediaClockClientCount == 0)

        let stream = controller.mediaClockSamples()
        #expect(controller.mediaClockClientCount == 1)

        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value

        try await waitForMediaClockClientCount(0, in: controller)
    }

    @Test
    func concurrentClientsHoldIndependentObservers() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }

        let first = controller.mediaClockSamples()
        let second = controller.mediaClockSamples()
        #expect(controller.mediaClockClientCount == 2)

        let firstConsumer = Task {
            for await _ in first {}
        }
        firstConsumer.cancel()
        await firstConsumer.value
        try await waitForMediaClockClientCount(1, in: controller)

        let secondConsumer = Task {
            for await _ in second {}
        }
        secondConsumer.cancel()
        await secondConsumer.value
        try await waitForMediaClockClientCount(0, in: controller)
    }

    @Test
    func loadedItemPrimesAnImmediatePausedSample() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 4
        )
        let controller = AVFoundationPlaybackController()
        let episode = Episode(
            id: EpisodeID(rawValue: "media-clock-prime"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Media Clock Prime",
            duration: 4,
            audioURL: fixtureURL
        )
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        try controller.load(episode)

        // The prime is buffered synchronously at subscribe, but the item's
        // media time can be momentarily invalid right after load; retry with
        // fresh subscriptions instead of waiting on a paused player that will
        // never produce periodic callbacks.
        var primed: PlaybackMediaClockSample?
        for _ in 0..<100 where primed == nil {
            let stream = controller.mediaClockSamples()
            let probe = Task {
                for await sample in stream {
                    return sample as PlaybackMediaClockSample?
                }
                return nil
            }
            try await Task.sleep(for: .milliseconds(20))
            probe.cancel()
            primed = await probe.value
        }

        let sample = try #require(primed)
        #expect(sample.isPlaying == false)
        #expect(sample.position >= 0)
    }

    @Test
    func idlePlayerYieldsNoPrimeSampleButInstallsObserver() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
        }

        let stream = controller.mediaClockSamples()
        #expect(controller.mediaClockClientCount == 1)

        // No current item means no meaningful media time; the stream stays
        // silent rather than yielding a non-finite position.
        let consumer = Task {
            var received: PlaybackMediaClockSample?
            for await sample in stream {
                received = sample
                break
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        let received = await consumer.value
        #expect(received == nil)
    }

    @Test
    func releasingControllerFinishesStreams() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        var controller: AVFoundationPlaybackController? = AVFoundationPlaybackController()
        let stream = try #require(controller?.mediaClockSamples())
        #expect(controller?.mediaClockClientCount == 1)

        controller?.unload()
        controller = nil

        // The deinit sweep finishes the continuation, so iteration terminates
        // instead of hanging on a dead player.
        for await _ in stream {}
    }

    private func waitForMediaClockClientCount(
        _ expected: Int,
        in controller: AVFoundationPlaybackController
    ) async throws {
        for _ in 0..<100 {
            if controller.mediaClockClientCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Media clock client count never reached \(expected).")
    }
}
