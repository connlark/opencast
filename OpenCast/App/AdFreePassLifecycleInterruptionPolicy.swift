import SwiftUI

nonisolated struct AdFreePassLifecycleInterruptionPolicy {
    static let inactiveInterruptionDelay: Duration = .seconds(2)

    var scenePhase: ScenePhase
    var isProtectingBackgroundExecution: Bool

    var decision: AdFreePassLifecycleInterruptionDecision {
        guard !isProtectingBackgroundExecution else {
            return .doNothing
        }

        switch scenePhase {
        case .inactive:
            return .scheduleDelayedInterrupt
        case .background:
            return .interruptNow
        case .active:
            return .doNothing
        @unknown default:
            return .doNothing
        }
    }
}
