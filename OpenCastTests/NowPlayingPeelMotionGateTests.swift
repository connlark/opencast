import CoreGraphics
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing peel motion gate")
struct NowPlayingPeelMotionGateTests {
    @Test("First update applies")
    func firstUpdateApplies() {
        var gate = NowPlayingPeelMotionGate()

        expectShouldApply(&gate, progress: 0, expected: true)
    }

    @Test("Idle repeat skips with or without Reduce Motion")
    func idleRepeatSkipsWithOrWithoutReduceMotion() {
        var standardGate = NowPlayingPeelMotionGate()
        expectShouldApply(&standardGate, expected: true)
        expectShouldApply(&standardGate, expected: false)

        var reduceMotionGate = NowPlayingPeelMotionGate()
        expectShouldApply(&reduceMotionGate, reduceMotion: true, expected: true)
        expectShouldApply(&reduceMotionGate, reduceMotion: true, expected: false)
    }

    @Test("Progress tolerance separates real changes from jitter")
    func progressToleranceSeparatesRealChangesFromJitter() {
        var gate = NowPlayingPeelMotionGate()

        expectShouldApply(&gate, progress: 0.4, expected: true)
        expectShouldApply(&gate, progress: 0.40005, expected: false)
        expectShouldApply(&gate, progress: 0.4002, expected: true)
        expectShouldApply(&gate, progress: 0.4002, expected: false)
    }

    @Test("Touch position changes apply")
    func touchPositionChangesApply() {
        var gate = NowPlayingPeelMotionGate()

        expectShouldApply(&gate, touchY: 0.76, expected: true)
        expectShouldApply(&gate, touchY: 0.76005, expected: false)
        expectShouldApply(&gate, touchY: 0.761, expected: true)
    }

    @Test("Active drags apply repeatedly")
    func activeDragsApplyRepeatedly() {
        var peelGate = NowPlayingPeelMotionGate()
        expectShouldApply(&peelGate, isPeelDragActive: true, expected: true)
        expectShouldApply(&peelGate, isPeelDragActive: true, expected: true)

        var dismissGate = NowPlayingPeelMotionGate()
        expectShouldApply(&dismissGate, isCardDismissDragActive: true, expected: true)
        expectShouldApply(&dismissGate, isCardDismissDragActive: true, expected: true)
    }

    @Test("Settle recording locks the post-settle idle pose")
    func settleRecordingLocksPostSettleIdlePose() {
        var gate = NowPlayingPeelMotionGate()
        gate.recordSettle(target: 1, touchY: 0.76, reduceMotion: false)

        expectShouldApply(&gate, progress: 1, expected: false)
        expectShouldApply(&gate, progress: 0.4, expected: true)
    }

    @Test("Reduce Motion changes apply once")
    func reduceMotionChangesApplyOnce() {
        var gate = NowPlayingPeelMotionGate()

        expectShouldApply(&gate, reduceMotion: false, expected: true)
        expectShouldApply(&gate, reduceMotion: true, expected: true)
        expectShouldApply(&gate, reduceMotion: true, expected: false)
    }

    @Test("Settle recording preserves Reduce Motion mode changes")
    func settleRecordingPreservesReduceMotionModeChanges() {
        var gate = NowPlayingPeelMotionGate()
        gate.recordSettle(target: 1, touchY: 0.76, reduceMotion: true)

        expectShouldApply(&gate, progress: 1, reduceMotion: false, expected: true)
        expectShouldApply(&gate, progress: 1, reduceMotion: false, expected: false)
    }

    private func expectShouldApply(
        _ gate: inout NowPlayingPeelMotionGate,
        progress: CGFloat = 0.4,
        touchY: CGFloat = 0.76,
        reduceMotion: Bool = false,
        isPeelDragActive: Bool = false,
        isCardDismissDragActive: Bool = false,
        expected: Bool
    ) {
        let didApply = gate.shouldApply(
            progress: progress,
            touchY: touchY,
            reduceMotion: reduceMotion,
            isPeelDragActive: isPeelDragActive,
            isCardDismissDragActive: isCardDismissDragActive
        )
        #expect(didApply == expected)
    }
}
