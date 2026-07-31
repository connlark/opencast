import Foundation

/// Decides whether an `.active` transition needs the full imported-data
/// maintenance pass (`reloadPersistedData` + duplicate repair). The first
/// activation after launch always runs it; later re-activations skip it
/// unless a non-self remote change was observed since the last completed
/// pass or the staleness ceiling has elapsed. Only the scene-phase path
/// consults this gate — initial setup, nuke recovery, and import flows call
/// the refresh directly and stay unconditional. A skipped pass is never
/// load-bearing: the remote-change reload path and the 60-second foreground
/// refresh loop remain untouched, and the ceiling backstops a missed signal.
struct ForegroundMaintenanceGate {
    static let stalenessCeiling: TimeInterval = 30 * 60

    private var hasObservedRemoteChangeSinceLastPass = false
    private var lastCompletedPassAt: Date?

    mutating func recordRemoteChange() {
        hasObservedRemoteChangeSinceLastPass = true
    }

    mutating func recordCompletedPass(at date: Date = .now) {
        lastCompletedPassAt = date
        hasObservedRemoteChangeSinceLastPass = false
    }

    func shouldRunMaintenancePass(now: Date = .now) -> Bool {
        guard let lastCompletedPassAt else {
            return true
        }
        if hasObservedRemoteChangeSinceLastPass {
            return true
        }
        return now.timeIntervalSince(lastCompletedPassAt) >= Self.stalenessCeiling
    }
}
