import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite
struct SleepTimerOptionTests {
    @Test
    func defaultPresetsRoundTripToPlaybackModes() {
        let options = SleepTimerOption.options(presets: SleepTimerPresetDuration.defaults)
        let expectedTitles = [
            "Off",
            "End of Episode",
            "5 Minutes",
            "10 Minutes",
            "15 Minutes",
            "30 Minutes",
            "45 Minutes",
            "1 Hour"
        ]
        let expectedModes: [PlaybackSleepTimerMode] = [
            PlaybackSleepTimerMode.off,
            .endOfEpisode,
            .duration(5 * 60),
            .duration(10 * 60),
            .duration(15 * 60),
            .duration(30 * 60),
            .duration(45 * 60),
            .duration(60 * 60)
        ]

        #expect(options.map(\.title) == expectedTitles)
        #expect(options.map(\.mode) == expectedModes)
    }

    @Test
    func presetsListShortestFirstWithoutDuplicates() {
        let options = SleepTimerOption.options(presets: [.oneHundredTwenty, .five, .ninety, .five, .twenty])

        #expect(options.map(\.title) == [
            "Off",
            "End of Episode",
            "5 Minutes",
            "20 Minutes",
            "1 Hour 30 Minutes",
            "2 Hours"
        ])
        #expect(options.map(\.mode).last == .duration(120 * 60))
    }
}
