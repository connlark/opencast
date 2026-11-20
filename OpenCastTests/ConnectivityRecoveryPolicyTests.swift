import Testing
@testable import OpenCast

@Suite("Connectivity recovery policy")
struct ConnectivityRecoveryPolicyTests {
    @Test("A satisfied path clears the marker and only an observed reconnect refreshes", arguments: [
        (Bool?.some(false), false, true, ConnectivityRecoveryDecision.doNothing),
        (.some(false), true, false, .clearMarkerAndRefresh),
        (.some(false), true, true, .clearMarkerAndRefresh),
        (.none, true, true, .clearMarker),
        (.some(true), true, true, .clearMarker),
        (.none, true, false, .doNothing),
    ])
    func decisionTable(previous: Bool?, isSatisfied: Bool, offline: Bool, expected: ConnectivityRecoveryDecision) {
        let decision = ConnectivityRecoveryPolicy(
            previousPathWasSatisfied: previous,
            pathIsSatisfied: isSatisfied,
            lastRefreshWasOffline: offline
        ).decision

        #expect(decision == expected)
    }
}
