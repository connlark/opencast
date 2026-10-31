import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing utility row width")
struct NowPlayingUtilityControlsLayoutTests {
    /// A 375 pt phone minus `NowPlayingContentMetrics`' 24 pt compact padding on each side.
    private let compactPhoneContentWidth = 375.0 - 2 * 24

    @Test("Five circles fit one row on a 375 pt phone at the default text size")
    func fiveCirclesFitAtDefaultSize() {
        let width = NowPlayingUtilityControls.rowWidth(
            circleCount: 5,
            scaledDiameter: PlayerUtilityCircleChrome.defaultDiameter
        )
        #expect(width == 308)
        #expect(width <= compactPhoneContentWidth)
    }

    @Test("Larger text that would overflow one row falls back to the grid; four circles still fit")
    func largerTextOverflowsFiveButNotFour() {
        // UIFontMetrics scales body 17 pt to 19 pt at xLarge and 23 pt at xxxLarge.
        let xLarge = PlayerUtilityCircleChrome.defaultDiameter * 19 / 17
        let xxxLarge = PlayerUtilityCircleChrome.defaultDiameter * 23 / 17
        #expect(NowPlayingUtilityControls.rowWidth(circleCount: 5, scaledDiameter: xLarge) > compactPhoneContentWidth)
        #expect(NowPlayingUtilityControls.rowWidth(circleCount: 4, scaledDiameter: xxxLarge) <= compactPhoneContentWidth)
    }

    @Test("Circles never shrink below the 44 pt tap target")
    func minimumDiameter() {
        #expect(NowPlayingUtilityControls.rowWidth(circleCount: 5, scaledDiameter: 30) == 5 * 44 + 4 * 12)
    }
}
