import OpenCastPlayback
import Testing
import UIKit
@testable import OpenCast

@MainActor
@Suite("Now Playing utility row width")
struct NowPlayingUtilityControlsLayoutTests {
    /// A 375 pt phone minus `NowPlayingContentMetrics`' 24 pt compact padding on each side.
    private let compactPhoneContentWidth = 375.0 - 2 * 24
    /// The play button at the default text size: 90 pt, under the 96 pt maximum.
    private let defaultPlayButtonDiameter = NowPlayingTransportControls.resolvedPlayButtonDiameter(
        scaled: NowPlayingTransportControls.playButtonBaseDiameter,
        isAccessibilitySize: false
    )

    @Test("Five circles fit one row on a 375 pt phone at the default text size")
    func fiveCirclesFitAtDefaultSize() {
        let width = NowPlayingUtilityControls.rowWidth(
            circleCount: 5,
            scaledDiameter: PlayerUtilityCircleChrome.defaultDiameter,
            playButtonDiameter: defaultPlayButtonDiameter
        )
        #expect(width == 308)
        #expect(width <= compactPhoneContentWidth)
    }

    @Test("Larger text that would overflow one row falls back to the grid; four circles still fit")
    func largerTextOverflowsFiveButNotFour() {
        // UIFontMetrics scales body 17 pt to 19 pt at xLarge and 23 pt at xxxLarge.
        let xLarge = PlayerUtilityCircleChrome.defaultDiameter * 19 / 17
        let xxxLarge = PlayerUtilityCircleChrome.defaultDiameter * 23 / 17
        let xxxLargePlay = NowPlayingTransportControls.resolvedPlayButtonDiameter(
            scaled: NowPlayingTransportControls.playButtonBaseDiameter * 23 / 17,
            isAccessibilitySize: false
        )
        #expect(NowPlayingUtilityControls.rowWidth(
            circleCount: 5,
            scaledDiameter: xLarge,
            playButtonDiameter: defaultPlayButtonDiameter
        ) > compactPhoneContentWidth)
        #expect(NowPlayingUtilityControls.rowWidth(
            circleCount: 4,
            scaledDiameter: xxxLarge,
            playButtonDiameter: xxxLargePlay
        ) <= compactPhoneContentWidth)
    }

    @Test("Circles never shrink below the 44 pt tap target")
    func minimumDiameter() {
        #expect(NowPlayingUtilityControls.rowWidth(
            circleCount: 5,
            scaledDiameter: 30,
            playButtonDiameter: defaultPlayButtonDiameter
        ) == 5 * 44 + 4 * 12)
    }

    @Test("Below the play button's size nothing is clamped: Dynamic Type's fonts and today's diameters")
    func unclampedAtDefaultSize() {
        let size = PlayerUtilityCircleSize(
            scaledDiameter: PlayerUtilityCircleChrome.defaultDiameter,
            playButtonDiameter: defaultPlayButtonDiameter
        )
        #expect(size.diameter == 52)
        #expect(!size.isClampedToPlayButton)
        #expect(size.glyphPointSize == nil)
        #expect(size.speedTextPointSize == nil)
    }

    /// The scaled metrics exactly as `@ScaledMetric(relativeTo: .body)` resolves them.
    private static func scaled(_ value: Double, at category: UIContentSizeCategory) -> Double {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: value,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
    }

    private static func resolvedSizes(at category: UIContentSizeCategory) -> (play: Double, circle: PlayerUtilityCircleSize) {
        let play = NowPlayingTransportControls.resolvedPlayButtonDiameter(
            scaled: scaled(NowPlayingTransportControls.playButtonBaseDiameter, at: category),
            isAccessibilitySize: category.isAccessibilityCategory
        )
        let circle = PlayerUtilityCircleSize(
            scaledDiameter: scaled(PlayerUtilityCircleChrome.defaultDiameter, at: category),
            playButtonDiameter: play
        )
        return (play, circle)
    }

    @Test("At AX XXL every circle is at most the resolved play button, and the label fonts follow the circle")
    func accessibilityXXLClampsToThePlayButton() throws {
        let (play, circle) = Self.resolvedSizes(at: .accessibilityExtraExtraLarge)
        #expect(play == 74)
        #expect(Self.scaled(PlayerUtilityCircleChrome.defaultDiameter, at: .accessibilityExtraExtraLarge) > play)
        #expect(circle.diameter == play)
        #expect(circle.isClampedToPlayButton)
        let glyph = try #require(circle.glyphPointSize)
        #expect(abs(glyph - play * 20 / 52) < 0.001)
        #expect(NowPlayingUtilityControls.rowWidth(
            circleCount: 4,
            scaledDiameter: Self.scaled(PlayerUtilityCircleChrome.defaultDiameter, at: .accessibilityExtraExtraLarge),
            playButtonDiameter: play
        ) == 4 * 74 + 3 * 12)
    }

    @Test("At AX XXL the widest speed label fits the clamped circle without shrinking")
    func accessibilityXXLSpeedTextFits() throws {
        let (_, circle) = Self.resolvedSizes(at: .accessibilityExtraExtraLarge)
        let pointSize = try #require(circle.speedTextPointSize)
        let font = UIFont.systemFont(ofSize: pointSize, weight: .bold)
        for rate in PlaybackRateSteps.steps {
            let width = (rate.formattedSpeed as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= circle.diameter, "\(rate.formattedSpeed) is \(width) pt wide in a \(circle.diameter) pt circle")
        }
    }

    @Test("No circle ever outgrows the play button resolved at the same size")
    func circleNeverOutgrowsThePlayButton() {
        let categories: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ]
        for category in categories {
            let (play, circle) = Self.resolvedSizes(at: category)
            #expect(circle.diameter <= play, "\(category.rawValue)")
            #expect(circle.diameter >= 44, "\(category.rawValue)")
        }
    }
}
