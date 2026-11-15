import Foundation

actor AudioSessionDeactivationProbe {
    private var callCount = 0
    private var finishedCallCount = 0
    private var finishedCountsAtStart: [Int] = []
    private var isReleased = false
    private var releasedCallCount = 0

    func deactivate() async {
        let callIndex = callCount
        callCount += 1
        finishedCountsAtStart.append(finishedCallCount)
        while !isReleased, releasedCallCount <= callIndex {
            await Task.yield()
        }
        finishedCallCount += 1
    }

    /// Lets every call finish, including later ones.
    func release() {
        isReleased = true
    }

    /// Lets the first `callCount` calls finish.
    func releaseCalls(through callCount: Int) {
        releasedCallCount = max(releasedCallCount, callCount)
    }

    func recordedCallCount() -> Int {
        callCount
    }

    func recordedFinishedCallCount() -> Int {
        finishedCallCount
    }

    /// For each call, how many calls had finished when it started: calls
    /// that run one after another read `[0, 1, 2, …]`.
    func recordedFinishedCountsAtStart() -> [Int] {
        finishedCountsAtStart
    }
}
