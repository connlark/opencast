import Foundation

/// Drag-to-turn math for the About hero, kept free of RealityKit and UIKit so
/// it can be unit-tested. Only horizontal drags turn the icon, so vertical
/// drags scroll the Form.
nonisolated enum SettingsAboutHeroYawGesture {
    enum Axis: Equatable {
        case horizontal
        case vertical
    }

    static let degreesPerPoint = 0.6
    static let maximumOffsetDegrees = 120.0
    /// How far ahead a release projects the drag's velocity, so a flick turns
    /// the icon over without dragging past a quarter turn.
    static let releaseProjectionSeconds = 0.2

    static func axis(for movement: CGSize) -> Axis {
        abs(movement.width) > abs(movement.height) ? .horizontal : .vertical
    }

    /// Yaw in radians away from the resting face, clamped so one drag can
    /// show at most a steep angle of the other face, never a full turn.
    static func offset(forHorizontalTranslation width: Double) -> Double {
        let degrees = min(max(width * degreesPerPoint, -maximumOffsetDegrees), maximumOffsetDegrees)
        return degrees * .pi / 180
    }

    static func releaseTranslation(translation: Double, velocity: Double) -> Double {
        translation + velocity * releaseProjectionSeconds
    }

    /// The face a release settles on: past a quarter turn, the other face.
    static func showsBack(afterReleasingAt offset: Double, showingBack: Bool) -> Bool {
        abs(offset) > .pi / 2 ? !showingBack : showingBack
    }
}
