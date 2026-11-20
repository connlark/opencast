import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite
struct SleepTimerOptionTests {
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
