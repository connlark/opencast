import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing Sound Lab interaction state")
struct NowPlayingSoundLabInteractionStateTests {
    @Test("Intended open follows settled, drag, and settle targets")
    func intendedOpenFollowsStateIntent() {
        #expect(!NowPlayingSoundLabInteractionState.closed.intendedOpen)
        #expect(!NowPlayingSoundLabInteractionState.openingDrag.intendedOpen)
        #expect(NowPlayingSoundLabInteractionState.open.intendedOpen)
        #expect(NowPlayingSoundLabInteractionState.closingDrag.intendedOpen)
        #expect(NowPlayingSoundLabInteractionState.settling(targetOpen: true).intendedOpen)
        #expect(!NowPlayingSoundLabInteractionState.settling(targetOpen: false).intendedOpen)
    }

    @Test("Only drag states track interaction")
    func onlyDragStatesTrackInteraction() {
        #expect(!NowPlayingSoundLabInteractionState.closed.isTrackingDrag)
        #expect(NowPlayingSoundLabInteractionState.openingDrag.isTrackingDrag)
        #expect(!NowPlayingSoundLabInteractionState.open.isTrackingDrag)
        #expect(NowPlayingSoundLabInteractionState.closingDrag.isTrackingDrag)
        #expect(!NowPlayingSoundLabInteractionState.settling(targetOpen: true).isTrackingDrag)
    }

    @Test("Settled state maps target openness")
    func settledStateMapsTargetOpenness() {
        #expect(NowPlayingSoundLabInteractionState.settled(open: true) == .open)
        #expect(NowPlayingSoundLabInteractionState.settled(open: false) == .closed)
    }
}
