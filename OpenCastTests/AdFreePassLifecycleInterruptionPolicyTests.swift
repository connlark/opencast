import SwiftUI
import Testing
@testable import OpenCast

@Suite("Ad-free pass lifecycle interruption policy")
struct AdFreePassLifecycleInterruptionPolicyTests {
    @Test("Protecting background execution suppresses inactive and background interruption")
    func protectingSuppressesInterruption() {
        #expect(decision(.inactive, protecting: true) == .doNothing)
        #expect(decision(.background, protecting: true) == .doNothing)
        #expect(decision(.active, protecting: true) == .doNothing)
    }

    @Test("Foreground-only behavior keeps existing inactive delay and background interrupt")
    func foregroundOnlyKeepsExistingBehavior() {
        #expect(decision(.inactive, protecting: false) == .scheduleDelayedInterrupt)
        #expect(decision(.background, protecting: false) == .interruptNow)
        #expect(decision(.active, protecting: false) == .doNothing)
    }

    private func decision(
        _ scenePhase: ScenePhase,
        protecting: Bool
    ) -> AdFreePassLifecycleInterruptionDecision {
        AdFreePassLifecycleInterruptionPolicy(
            scenePhase: scenePhase,
            isProtectingBackgroundExecution: protecting
        ).decision
    }
}
