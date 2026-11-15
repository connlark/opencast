import Foundation
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct PlaybackSkipCuePlayerTests {
    @Test("The real cue opens unprepared, plays, completes, and replays from the start after a stop")
    func playsCompletesAndReplaysFromStart() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let url = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a",
            settings: VoiceBoostAudioFixture.aacSettings(),
            duration: 0.4
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let cue = try PlaybackSkipCuePlayer(contentsOf: url)
        var finishCount = 0
        cue.onFinish = { finishCount += 1 }
        #expect(!cue.isPrepared)
        #expect(!cue.isSounding)

        cue.prepare()
        #expect(cue.isPrepared)
        #expect(cue.play())
        #expect(cue.isSounding)
        try await waitUntil { finishCount == 1 }
        #expect(!cue.isSounding)

        #expect(cue.play())
        try await waitUntil { cue.currentTime > 0.1 }
        cue.stop()
        #expect(!cue.isSounding)
        #expect(cue.currentTime > 0.1)

        #expect(cue.play())
        #expect(cue.currentTime < 0.1)
        #expect(cue.isSounding)
        try await waitUntil { finishCount == 2 }
        #expect(!cue.isSounding)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(30)
        while !predicate(), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Timed out waiting for the cue")
    }
}
