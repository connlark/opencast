import Foundation
import OpenCastCore
import OpenCastVoiceBoost
import Testing
@testable import OpenCastPlayback

struct VoiceBoostDownloadHandoffTests {
    @Test(arguments: [false, true])
    @MainActor
    func remoteToLocalKeepsAdaptationAndNewLoadStartsFresh(disabledAtHandoff: Bool) async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let fileURL = try VoiceBoostAudioFixture.writeSine(
            fileExtension: "m4a", settings: VoiceBoostAudioFixture.aacSettings(), duration: 30
        )
        let server = try HTTPFixtureServer(
            data: Data(contentsOf: fileURL), fileName: "handoff.m4a", contentType: "audio/mp4"
        )
        var taps: [VoiceBoostAudioTap] = []
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: diagnostics,
            voiceBoostAudioTapFactory: { configuration, diagnostics in
                let tap = try VoiceBoostAudioTap(configuration: configuration, diagnostics: diagnostics)
                taps.append(tap)
                return tap
            }
        )
        defer {
            controller.unload()
            server.stop()
            try? FileManager.default.removeItem(at: fileURL)
        }
        let episode = Episode(
            id: EpisodeID(rawValue: "handoff"),
            podcastID: PodcastID(rawValue: "https://example.com/feed.xml"),
            podcastTitle: "Handoff fixture", title: "Handoff fixture", duration: 30, audioURL: server.url
        )
        try controller.load(episode)
        controller.play()
        try await waitUntil { (taps.last?.captureContinuationState()?.integratedBlockCount ?? 0) >= 40 }
        if disabledAtHandoff {
            controller.setVoiceBoostEnabled(false)
            controller.pause()
        }
        let before = try #require(taps.last?.captureContinuationState())
        let position = controller.position
        let installCount = taps.count
        #expect(controller.useDownloadedAudio(at: fileURL, for: episode.id))
        #expect(controller.currentItemSourceIdentity?.assetURL == fileURL)
        if disabledAtHandoff {
            // Keep history without adding a dormant audio callback pipeline.
            #expect(taps.count == installCount)
            #expect(controller.snapshot.state == .paused)
            controller.setVoiceBoostEnabled(true)
        }
        #expect(taps.count > installCount)
        let carried = try #require(taps.last?.captureContinuationState())
        #expect(carried.integratedBlockCount >= before.integratedBlockCount)
        #expect(abs(carried.controlSnapshot.currentAutoGainDB - before.controlSnapshot.currentAutoGainDB) < 0.1)
        #expect(abs(controller.position - position) < 0.2)

        if disabledAtHandoff {
            controller.play()
        }
        // The asynchronous track-bound reinstall must also retain the state.
        try await waitUntil { diagnostics.snapshot.processedFrameCount > 44_100 * 7 }
        #expect((taps.last?.captureContinuationState()?.integratedBlockCount ?? 0) > before.integratedBlockCount)
        #expect(diagnostics.snapshot.sourceErrorCount == 0)
        #expect(diagnostics.snapshot.unsupportedFormatCount == 0)

        controller.pause()
        let historyBeforeSeek = try #require(taps.last?.captureContinuationState()).integratedBlockCount
        controller.seek(to: 12)
        #expect((taps.last?.captureContinuationState()?.integratedBlockCount ?? 0) >= historyBeforeSeek)
        controller.setSkipZones([PlaybackSkipZone(id: 1, startTime: 11, endTime: 15)])
        // Installing a matching zone over the playhead can immediately skip.
        #expect(controller.lastAutoSkipEvent?.zoneID == 1)
        #expect(controller.position == 15)
        #expect((taps.last?.captureContinuationState()?.integratedBlockCount ?? 0) >= historyBeforeSeek)

        // Even the same episode ID loaded explicitly is a fresh listen. A late
        // task from the old item cannot seed this item's tap.
        try controller.load(episode)
        try await Task.sleep(for: .milliseconds(200))
        #expect((taps.last?.captureContinuationState()?.integratedBlockCount ?? 0) == 0)
        #expect(controller.currentItemSourceIdentity?.assetURL == server.url)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(30)
        while !condition(), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "Timed out waiting for real audio processing")
    }
}
