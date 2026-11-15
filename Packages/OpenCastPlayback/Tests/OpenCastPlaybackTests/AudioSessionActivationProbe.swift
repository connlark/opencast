import Foundation

actor AudioSessionActivationProbe {
    enum Outcome: Sendable {
        case success
        case failure
    }

    struct Failure: Error {}

    private let outcomes: [Outcome]
    private var callCount = 0
    private var releasedCallCount = 0
    private var releasedCallIndices: Set<Int> = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func activate() async throws -> Bool {
        let callIndex = callCount
        callCount += 1

        while releasedCallCount <= callIndex, !releasedCallIndices.contains(callIndex) {
            try Task.checkCancellation()
            await Task.yield()
        }

        guard outcomes.indices.contains(callIndex) else {
            return false
        }
        switch outcomes[callIndex] {
        case .success:
            return false
        case .failure:
            throw Failure()
        }
    }

    func releaseCalls(through callCount: Int) {
        releasedCallCount = max(releasedCallCount, callCount)
    }

    /// Lets the call at `index` (zero-based) return ahead of earlier ones.
    func releaseCall(at index: Int) {
        releasedCallIndices.insert(index)
    }

    func recordedCallCount() -> Int {
        callCount
    }
}
