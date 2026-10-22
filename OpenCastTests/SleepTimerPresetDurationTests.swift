import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite
struct SleepTimerPresetDurationTests {
    @Test(arguments: [
        (SleepTimerPresetDuration.five, "5 Minutes", 300 as TimeInterval),
        (.ten, "10 Minutes", 600),
        (.fifteen, "15 Minutes", 900),
        (.twenty, "20 Minutes", 1_200),
        (.thirty, "30 Minutes", 1_800),
        (.fortyFive, "45 Minutes", 2_700),
        (.sixty, "1 Hour", 3_600),
        (.ninety, "1 Hour 30 Minutes", 5_400),
        (.oneHundredTwenty, "2 Hours", 7_200)
    ])
    func titlesAndSecondsMatchTheMinutes(
        duration: SleepTimerPresetDuration,
        title: String,
        seconds: TimeInterval
    ) {
        #expect(duration.title == title)
        #expect(duration.seconds == seconds)
    }

    @Test
    func defaultsAreFiveToSixtyMinutes() {
        #expect(SleepTimerPresetDuration.defaults.map(\.minutes) == [5, 10, 15, 30, 45, 60])
        #expect(SleepTimerPresetDuration.allCases.count == 9)
        #expect(SleepTimerPresetDuration.allCases == SleepTimerPresetDuration.allCases.sorted())
    }
}
