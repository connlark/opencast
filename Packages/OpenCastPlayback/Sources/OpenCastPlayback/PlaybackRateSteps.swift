import Foundation

/// The playback speeds OpenCast offers everywhere it offers a choice: the phone's
/// Speed sheet, the system's `supportedPlaybackRates`, and the car's rate button.
/// The clamp accepts 0.5–3.0, so `next(after:)` also has to answer for rates that
/// are not steps.
public nonisolated enum PlaybackRateSteps {
    public static let steps: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    public static func clamped(_ rate: Float) -> Float {
        guard rate.isFinite else {
            return 1
        }

        return min(max(rate, 0.5), 3)
    }

    /// The next step above `rate`, wrapping to the slowest step once past the
    /// fastest. Comparing with a tolerance keeps a rate that round-tripped
    /// through `Float` arithmetic from selecting itself.
    public static func next(after rate: Float) -> Float {
        let tolerance: Float = 0.0001
        return steps.first { $0 > rate + tolerance } ?? steps.first ?? 1
    }
}
