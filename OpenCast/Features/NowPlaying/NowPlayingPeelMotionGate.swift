import CoreGraphics

struct NowPlayingPeelMotionGate {
    private struct RecordedInputs {
        var progress: CGFloat
        var touchY: CGFloat
        var reduceMotion: Bool

        init(progress: CGFloat, touchY: CGFloat, reduceMotion: Bool) {
            self.progress = progress.clamped01
            self.touchY = touchY.clamped01
            self.reduceMotion = reduceMotion
        }

        func isMeaningfullyDifferent(from other: Self, tolerance: CGFloat) -> Bool {
            abs(progress - other.progress) > tolerance
                || abs(touchY - other.touchY) > tolerance
                || reduceMotion != other.reduceMotion
        }
    }

    private static let tolerance: CGFloat = 0.0001
    private var recordedInputs: RecordedInputs?

    mutating func shouldApply(
        progress: CGFloat,
        touchY: CGFloat,
        reduceMotion: Bool,
        isPeelDragActive: Bool,
        isCardDismissDragActive: Bool
    ) -> Bool {
        let nextInputs = RecordedInputs(
            progress: progress,
            touchY: touchY,
            reduceMotion: reduceMotion
        )

        if isPeelDragActive || isCardDismissDragActive {
            recordedInputs = nextInputs
            return true
        }

        guard let recordedInputs else {
            self.recordedInputs = nextInputs
            return true
        }

        guard recordedInputs.isMeaningfullyDifferent(from: nextInputs, tolerance: Self.tolerance) else {
            return false
        }

        self.recordedInputs = nextInputs
        return true
    }

    mutating func recordSettle(target: CGFloat, touchY: CGFloat, reduceMotion: Bool) {
        recordedInputs = RecordedInputs(
            progress: target,
            touchY: touchY,
            reduceMotion: reduceMotion
        )
    }
}
