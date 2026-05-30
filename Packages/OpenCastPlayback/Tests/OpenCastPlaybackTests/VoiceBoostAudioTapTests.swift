@preconcurrency import AVFoundation
import Foundation
import OpenCastVoiceBoost
import Testing
@testable import OpenCastPlayback

struct VoiceBoostAudioTapTests {
    @Test
    func createsMediaToolboxTap() throws {
        _ = try VoiceBoostAudioTap(configuration: .default)
    }

    @Test
    @MainActor
    func processesLocalPlayerItemAudio() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(fileExtension: "caf")
        try await expectTapProcessesAudio(from: fixtureURL)
    }

    @Test
    @MainActor
    func processesLocalCompressedPlayerItemAudio() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer {
            AVFoundationPlaybackTestGate.release()
        }

        let fixtureURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings()
        )
        try await expectTapProcessesAudio(from: fixtureURL)
    }

    @MainActor
    private func expectTapProcessesAudio(from fixtureURL: URL) async throws {
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let tap = try VoiceBoostAudioTap(configuration: .default, diagnostics: diagnostics)
        let item = AVPlayerItem(url: fixtureURL)
        let inputParameters = AVMutableAudioMixInputParameters()
        inputParameters.audioTapProcessor = tap.audioTapProcessor

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParameters]
        item.audioMix = audioMix

        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.playImmediately(atRate: 1)
        defer {
            player.pause()
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        let deadline = Date.now.addingTimeInterval(5)
        while diagnostics.snapshot.processedFrameCount == 0 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let snapshot = diagnostics.snapshot
        #expect(snapshot.prepareCount > 0)
        #expect(snapshot.processCount > 0)
        #expect(snapshot.timedProcessCount == snapshot.processCount)
        #expect(snapshot.maxProcessDurationNanoseconds >= snapshot.lastProcessDurationNanoseconds)
        #expect(snapshot.totalProcessDurationNanoseconds >= snapshot.lastProcessDurationNanoseconds)
        #expect(snapshot.processedFrameCount > 0)
        #expect(snapshot.sourceErrorCount == 0)
        #expect(snapshot.unsupportedFormatCount == 0)
    }
}
