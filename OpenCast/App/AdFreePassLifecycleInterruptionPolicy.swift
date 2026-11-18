import SwiftUI

nonisolated struct AdFreePassLifecycleInterruptionPolicy {
    /// How long a scene may stay inactive, or playback stay stopped with no
    /// scene active, before on-device work is stopped.
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
