import Foundation

/// The clamp accepts 0.5 to 3.0, so `next(after:)` also answers for rates that are not steps.
public nonisolated enum PlaybackRateSteps {
    public static let steps: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    public static func clamped(_ rate: Float) -> Float {
        guard rate.isFinite else {
            return 1
        }

        return min(max(rate, 0.5), 3)
    }

    /// Wraps past the fastest step. The tolerance keeps a rate that round-tripped through `Float`
    /// arithmetic from selecting itself.
    public static func next(after rate: Float) -> Float {
        let tolerance: Float = 0.0001
        return steps.first { $0 > rate + tolerance } ?? steps.first ?? 1
    }
}
