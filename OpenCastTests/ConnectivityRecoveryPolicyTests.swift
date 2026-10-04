import Testing
@testable import OpenCast

@Suite("Connectivity recovery policy")
struct ConnectivityRecoveryPolicyTests {
    @Test("Without the offline marker only an observed reconnect refreshes")
    func noMarkerStillPreservesReconnect() {
        for previous in [nil, true] as [Bool?] {
            #expect(decision(previous: previous, isSatisfied: true, offline: false) == .doNothing)
        }
        #expect(decision(previous: false, isSatisfied: true, offline: false) == .clearMarkerAndRefresh)
        for previous in [nil, false, true] as [Bool?] {
            #expect(decision(previous: previous, isSatisfied: false, offline: false) == .doNothing)
        }
    }

    @Test("An unsatisfied path keeps the marker")
    func unsatisfiedPathDoesNothing() {
        #expect(decision(previous: nil, isSatisfied: false, offline: true) == .doNothing)
        #expect(decision(previous: false, isSatisfied: false, offline: true) == .doNothing)
        #expect(decision(previous: true, isSatisfied: false, offline: true) == .doNothing)
    }

    @Test("An observed reconnect clears the marker and refreshes")
    func reconnectClearsAndRefreshes() {
        #expect(decision(previous: false, isSatisfied: true, offline: true) == .clearMarkerAndRefresh)
    }

    @Test("A satisfied path without an observed reconnect only clears the marker")
    func satisfiedWithoutTransitionOnlyClears() {
        #expect(decision(previous: nil, isSatisfied: true, offline: true) == .clearMarker)
        #expect(decision(previous: true, isSatisfied: true, offline: true) == .clearMarker)
    }

    private func decision(
        previous: Bool?,
        isSatisfied: Bool,
        offline: Bool
    ) -> ConnectivityRecoveryDecision {
        ConnectivityRecoveryPolicy(
            previousPathWasSatisfied: previous,
            pathIsSatisfied: isSatisfied,
            lastRefreshWasOffline: offline
        ).decision
    }
}
