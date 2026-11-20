import Foundation

struct ForegroundMaintenanceGate {
    /// Backstops a missed remote-change signal.
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
