import OpenCastPlayback
import Testing
import UIKit
@testable import OpenCast

@MainActor
@Suite("Now Playing utility row width")
struct NowPlayingUtilityControlsLayoutTests {
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
}
