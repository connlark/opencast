import SwiftUI

/// The diameter stays between the 44 pt tap target and the play-button diameter resolved at
/// the same Dynamic Type size.
nonisolated struct PlayerUtilityCircleSize: Equatable {
    /// A circle clamped to the play button keeps these shares of the default circle: Dynamic Type
    /// alone would overflow it.
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
