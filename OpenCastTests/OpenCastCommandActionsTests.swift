@preconcurrency import AVFoundation
import Foundation
import OpenCastCore
import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite("OpenCast command actions")
struct OpenCastCommandActionsTests {
    @Test(arguments: [1.0, -1.0])
    func keyboardSkipsUseSkipButtonAdPolicy(interval: TimeInterval) async throws {
        let fixtureURL = try writeAudioFixture(duration: 5)
        let controller = AVFoundationPlaybackController()
        defer {
            controller.unload()
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        try controller.load(episode(audioURL: fixtureURL))
        controller.setSkipIntervals(backward: 1, forward: 1)
        controller.setSkipZones([
            PlaybackSkipZone(id: 7, startTime: 0.5, endTime: 2)
        ])
        controller.setAutoSkipEnabled(true)
        if interval < 0 {
            controller.seek(to: 2.5)
        }
        let actions = OpenCastCommandActions.make(
            playback: controller,
            focusSearch: {}
        )

        if interval > 0 {
            actions.seekForward()
        } else {
            actions.seekBackward()
        }

        let deadline = Date.now.addingTimeInterval(3)
        while controller.lastAutoSkipEvent == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(controller.position >= 2)
        #expect(controller.lastAutoSkipEvent?.zoneID == 7)
    }

    @Test("Playback shortcuts are inert without a loaded episode")
    func shortcutsAreNoOpsWithoutEpisode() {
        let controller = AVFoundationPlaybackController()
        let actions = OpenCastCommandActions.make(
            playback: controller,
            focusSearch: {}
        )

        actions.togglePlayback()
        actions.seekBackward()
        actions.seekForward()

        #expect(controller.state == .idle)
        #expect(controller.position == 0)
        #expect(controller.currentEpisode == nil)
    }

    private func episode(audioURL: URL) -> Episode {
        Episode(
            id: EpisodeID(rawValue: "keyboard-command-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/commands.xml"),
            podcastTitle: "Command Show",
            title: "Command Episode",
            duration: 5,
            audioURL: audioURL
        )
    }

    private func writeAudioFixture(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "opencast-command-actions-\(UUID().uuidString).m4a")
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
            samples[frame] = Float(sin(phase) * 0.12)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
        )
        try file.write(from: buffer)
        return url
    }
}
