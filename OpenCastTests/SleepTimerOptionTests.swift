import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite
struct SleepTimerOptionTests {
    @Test
    func canonicalOptionsRoundTripToPlaybackModes() {
        let titles = SleepTimerOption.canonical.map(\.title)
        let expectedTitles = [
            "Off",
            "End of Episode",
            "15 Minutes",
            "30 Minutes",
            "45 Minutes",
            "1 Hour"
        ]
        let modes = SleepTimerOption.canonical.map(\.mode)
        let expectedModes: [PlaybackSleepTimerMode] = [
            PlaybackSleepTimerMode.off,
            .endOfEpisode,
            .duration(15 * 60),
            .duration(30 * 60),
            .duration(45 * 60),
            .duration(60 * 60)
        ]

        #expect(titles == expectedTitles)
        #expect(modes == expectedModes)
    }
}
