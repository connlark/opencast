nonisolated struct ConnectivityRecoveryPolicy {
    /// Nil for the first path report after the scene became active.
    var previousPathWasSatisfied: Bool?
    var pathIsSatisfied: Bool
    var lastRefreshWasOffline: Bool

    /// Only an observed offline-to-online transition refreshes: a first satisfied
    /// report may follow a background reconnect the activation pass covered.
    var decision: ConnectivityRecoveryDecision {
        guard pathIsSatisfied else {
            return .doNothing
        }

        // The reconnect can arrive before an outstanding offline fetch result
        // sets the marker, so the transition alone refreshes.
        if previousPathWasSatisfied == false {
            return .clearMarkerAndRefresh
        }
        return lastRefreshWasOffline ? .clearMarker : .doNothing
    }
}
