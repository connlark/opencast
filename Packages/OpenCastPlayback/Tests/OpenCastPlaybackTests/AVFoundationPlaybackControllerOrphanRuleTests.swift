import Foundation
import OpenCastCore
import Testing
@testable import OpenCastPlayback

/// Rule 8 of lane A2: the orphan rule in completeAudioSessionActivation's
/// stale-generation branch must not release a session the preview owns or
/// is acquiring. This test stages the interleaving that does exactly that.
@MainActor
@Suite
struct AVFoundationPlaybackControllerOrphanRuleTests {
    private let previewURL = URL(filePath: "/tmp/opencast-skip-cue-preview-a.m4a")

    @Test("An episode activation orphaned by an unload leaves alone a session a later preview takes")
    func orphanedEpisodeActivationLeavesThePreviewSessionAlone() async throws {
        try await AVFoundationPlaybackTestGate.acquire()
        defer { AVFoundationPlaybackTestGate.release() }
        let activation = AudioSessionActivationProbe(outcomes: [.success, .success])
        let deactivation = AudioSessionDeactivationProbe()
        let factory = SkipCuePlayerFactorySpy()
        let controller = AVFoundationPlaybackController(
            voiceBoostTapDiagnostics: nil,
            audioSessionActivation: { try await activation.activate() },
            audioSessionDeactivation: { await deactivation.deactivate() },
            skipCuePlayerFactory: { try factory.make($0) }
        )
        defer { controller.unload() }

        // 1. An episode activation is in flight.
        try controller.load(episode(duration: 240))
        controller.play()
        try await waitUntil { await activation.recordedCallCount() == 1 }
        // 2. Its system activation returns (released before the unload, so
        //    it returns instead of throwing as cancelled) ...
        await activation.releaseCalls(through: 1)
        // 3. ... but before its completion runs on the main actor, the
        //    episode is unloaded and a preview starts. Nothing holds the
        //    session, so the preview starts its own acquisition.
        controller.unload()
        controller.previewAutoSkipCue(previewURL)
        try await waitUntil { await activation.recordedCallCount() == 2 }
        await yieldToPendingWork()

        // 4. The orphaned completion found no episode task and an inactive
        //    session, so it scheduled a release while the preview acquires.
        let releasesWhileAcquiring = await deactivation.recordedCallCount()
        #expect(releasesWhileAcquiring == 0)

        // 5. The preview's activation completes current: it owns the session
        //    and plays, with the orphan's release still pending behind it.
        await activation.releaseCalls(through: 2)
        try await waitUntil { factory.latestCue != nil }
        await yieldToPendingWork()
        let releasesWhileOwning = await deactivation.recordedFinishedCallCount()
        #expect(releasesWhileOwning == 0)
        await deactivation.release()
        await yieldToPendingWork()
        #expect(factory.latestCue?.isSounding == true)
        #expect(await deactivation.recordedFinishedCallCount() == 0, "a release landed while the preview owns the session")

        // 6. One release, after the preview's sound ends.
        factory.latestCue?.finish()
        try await waitUntil { await deactivation.recordedCallCount() >= 1 }
        await yieldToPendingWork()
        #expect(await deactivation.recordedCallCount() == 1)
    }

    private func yieldToPendingWork() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(60)
        while Date.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for playback test condition.")
    }
}
