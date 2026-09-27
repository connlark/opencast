import Foundation
import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite
struct SleepTimerRemainingTextTests {
    @Test(arguments: [
        (PlaybackSleepTimerMode.off, nil as TimeInterval?, "Off"),
        (.endOfEpisode, nil, "End of Episode"),
        (.endOfEpisode, 125, "-2:05"),
        (.duration(900), 899, "-14:59"),
        (.duration(900), 0, "Off")
    ])
    func describesTheTimerState(mode: PlaybackSleepTimerMode, remaining: TimeInterval?, expected: String) {
        #expect(SleepTimerRemainingText.text(mode: mode, remaining: remaining) == expected)
    }
}
