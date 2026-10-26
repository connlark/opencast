import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization

/// A key tester that answers with seeded results without any network: UI
/// tests and previews. Call n answers `results[n - 1]` (the last repeats),
/// after the gate releases it, if there is one, and after `delay`. Neither
/// wait ends early on cancellation: a cancelled request still answers, late,
/// as a slow provider would.
nonisolated struct FixedAnalysisKeyTester: AnalysisKeyTesting {
    let results: [AnalysisKeyTestResult]
    let delay: Duration
    let gate: AnalysisKeyTestReleaseGate?
    private let calls = CallCounter()

    init(result: AnalysisKeyTestResult = .accepted, delay: Duration = .zero) {
        self.init(results: [result], delay: delay)
    }

    init(results: [AnalysisKeyTestResult], delay: Duration = .zero, gate: AnalysisKeyTestReleaseGate? = nil) {
        self.results = results.isEmpty ? [.accepted] : results
        self.delay = delay
        self.gate = gate
    }

    func test(_ key: AnalysisProviderKey, provider: AnalysisProvider, snapshot: AnalysisPolicySnapshot) async -> AnalysisKeyTestResult {
        let call = calls.next()
        if let gate {
            await gate.wait(call: call)
        }
        if delay > .zero {
            let delay = delay
            await Task.detached {
                try? await Task.sleep(for: delay)
            }.value
        }
        return results[min(call, results.count) - 1]
    }
}

private nonisolated final class CallCounter: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}
