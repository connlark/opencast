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

        // Media time can be invalid right after load, and a paused player never
        // fires periodic callbacks, so retry with fresh subscriptions.
        var primed: PlaybackMediaClockSample?
        let deadline = Date.now.addingTimeInterval(60)
        while primed == nil, Date.now < deadline {
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

        for await _ in stream {}
    }

    @Test("A media clock client keeps receiving samples after a media services reset")
    func clientKeepsReceivingSamplesAfterMediaServicesReset() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 180
        )
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        try controller.load(Episode(
            id: EpisodeID(rawValue: "media-clock-reset"),
            podcastID: PodcastID(rawValue: "podcast"),
            podcastTitle: "Podcast",
            title: "Media Clock Reset",
            duration: 180,
            audioURL: fixtureURL
        ))
        var latestPlayingPosition: TimeInterval?
        let stream = controller.mediaClockSamples()
        let consumer = Task {
            for await sample in stream where sample.isPlaying {
                latestPlayingPosition = sample.position
            }
        }
        defer {
            consumer.cancel()
        }
        controller.play()
        try await waitForPlayingPosition { latestPlayingPosition != nil }

        controller.handleAudioSessionMediaServicesWereReset()
        let positionAtReset = try #require(latestPlayingPosition)

        // Half a second is past anything the stream buffered before the reset.
        try await waitForPlayingPosition { (latestPlayingPosition ?? 0) > positionAtReset + 0.5 }
    }

    private func waitForPlayingPosition(_ predicate: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(60)
        while Date.now < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The media clock never delivered the expected playing sample.")
    }

    private func waitForMediaClockClientCount(
        _ expected: Int,
        in controller: AVFoundationPlaybackController
    ) async throws {
        let deadline = Date.now.addingTimeInterval(60)
        while Date.now < deadline {
            if controller.mediaClockClientCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Media clock client count never reached \(expected).")
    }
}
