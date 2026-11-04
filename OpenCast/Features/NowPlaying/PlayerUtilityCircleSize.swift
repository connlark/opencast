import SwiftUI

/// A utility circle's diameter and label fonts. The scaled 52 pt circle never
/// grows past the resolved play-button diameter at the same Dynamic Type size,
/// and never shrinks below the 44 pt tap target.
nonisolated struct PlayerUtilityCircleSize: Equatable {
    /// title3's and body's share of the default circle. A circle clamped to
    /// the play button keeps these proportions; Dynamic Type alone would
    /// overflow it, so the clamped labels take an explicit point size.
    private static let glyphShare = 20.0 / PlayerUtilityCircleChrome.defaultDiameter
    private static let speedTextShare = 17.0 / PlayerUtilityCircleChrome.defaultDiameter

    let diameter: Double
    let isClampedToPlayButton: Bool

    init(scaledDiameter: Double, playButtonDiameter: Double) {
        diameter = PlayerUtilityCircleChrome.diameter(scaled: scaledDiameter, playButtonDiameter: playButtonDiameter)
        isClampedToPlayButton = diameter < PlayerUtilityCircleChrome.diameter(
            scaled: scaledDiameter,
            playButtonDiameter: .infinity
        )
    }

    /// Nil while Dynamic Type's title3 still fits.
    var glyphPointSize: Double? {
        isClampedToPlayButton ? diameter * Self.glyphShare : nil
    }

    /// Nil while Dynamic Type's body still fits.
    var speedTextPointSize: Double? {
        isClampedToPlayButton ? diameter * Self.speedTextShare : nil
    }

    var glyphFont: Font {
        glyphPointSize.map { .system(size: $0) } ?? .title3
    }

    var speedTextFont: Font {
        speedTextPointSize.map { .system(size: $0) } ?? .body
    }
}
