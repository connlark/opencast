import Foundation
import Testing
@testable import OpenCastPlayback

@MainActor
@Suite
struct PlaybackEndOfEpisodeSleepTimerTests {
    @Test
    func remainingPlaybackDurationTracksPositionAndRate() {
        #expect(PlaybackEndOfEpisodeSleepTimer.remainingPlaybackDuration(
            endPosition: 600,
            position: 120,
            rate: 1
        ) == 480)
        #expect(PlaybackEndOfEpisodeSleepTimer.remainingPlaybackDuration(
            endPosition: 600,
            position: 120,
            rate: 2
        ) == 240)
    }

    @Test
    func unavailableOrCompletedEpisodeHasNoDuration() {
        #expect(PlaybackEndOfEpisodeSleepTimer.remainingPlaybackDuration(
            endPosition: nil,
            position: 0,
            rate: 1
        ) == nil)
        #expect(PlaybackEndOfEpisodeSleepTimer.remainingPlaybackDuration(
            endPosition: 600,
            position: 600,
            rate: 1
        ) == nil)
    }
}
