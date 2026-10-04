nonisolated struct ConnectivityRecoveryPolicy {
    /// Nil for the first path report after the scene became active.
    var previousPathWasSatisfied: Bool?
    var pathIsSatisfied: Bool
    var lastRefreshWasOffline: Bool

    /// Only an observed offline-to-online transition refreshes. A first
    /// satisfied report may follow a reconnect made while backgrounded, which
    /// the activation pass already covers, and a pass that ran offline on
    /// fresh feeds leaves nothing stale; both still need the marker cleared.
    var decision: ConnectivityRecoveryDecision {
        guard pathIsSatisfied else {
            return .doNothing
        }

        // The reconnect can precede delivery of an outstanding offline fetch
        // result. Preserve it even before that result sets the marker.
        if previousPathWasSatisfied == false {
            return .clearMarkerAndRefresh
        }
        return lastRefreshWasOffline ? .clearMarker : .doNothing
    }
}
