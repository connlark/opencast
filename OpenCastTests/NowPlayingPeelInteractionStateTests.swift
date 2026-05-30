import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing peel interaction state")
struct NowPlayingPeelInteractionStateTests {
    @Test("Closing settle resolves when progress reaches closed")
    func closingSettleResolvesWhenProgressReachesClosed() {
        let state = NowPlayingPeelInteractionState.settling(targetOpen: false)

        #expect(state.settledIfNeeded(progress: 0) == .closed)
        #expect(state.settledIfNeeded(progress: 0.001) == .closed)
        #expect(state.settledIfNeeded(progress: 0.01) == nil)
    }

    @Test("Opening settle resolves when progress reaches open")
    func openingSettleResolvesWhenProgressReachesOpen() {
        let state = NowPlayingPeelInteractionState.settling(targetOpen: true)

        #expect(state.settledIfNeeded(progress: 1) == .open)
        #expect(state.settledIfNeeded(progress: 0.999) == .open)
        #expect(state.settledIfNeeded(progress: 0.99) == nil)
    }

    @Test("Non-settling states do not resolve")
    func nonSettlingStatesDoNotResolve() {
        #expect(NowPlayingPeelInteractionState.closed.settledIfNeeded(progress: 0) == nil)
        #expect(NowPlayingPeelInteractionState.open.settledIfNeeded(progress: 1) == nil)
    }
}
