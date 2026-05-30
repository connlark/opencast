import Testing
@testable import OpenCastPlayback

@Suite
@MainActor
struct PlaybackSnapshotTests {
    @Test
    func normalizedProgressClampsIntoUnitRange() {
        let snapshot = PlaybackSnapshot(position: 45, duration: 90)

        #expect(snapshot.normalizedProgress == 0.5)
        #expect(snapshot.normalizedProgress(for: -10) == 0)
        #expect(snapshot.normalizedProgress(for: 120) == 1)
    }

    @Test
    func normalizedProgressFallsBackToZeroWhenDurationIsUnavailable() {
        #expect(PlaybackSnapshot(position: 45, duration: nil).normalizedProgress == 0)
        #expect(PlaybackSnapshot(position: 45, duration: 0).normalizedProgress == 0)
        #expect(PlaybackSnapshot(position: .infinity, duration: 90).normalizedProgress == 0)
    }

    @Test
    func playbackStateAccessibilityDescriptionIsShared() {
        #expect(PlaybackState.idle.accessibilityDescription == "Idle")
        #expect(PlaybackState.loading.accessibilityDescription == "Loading")
        #expect(PlaybackState.buffering.accessibilityDescription == "Buffering")
        #expect(PlaybackState.paused.accessibilityDescription == "Paused")
        #expect(PlaybackState.playing.accessibilityDescription == "Playing")
        #expect(PlaybackState.failed("offline").accessibilityDescription == "Playback Failed")
    }
}
