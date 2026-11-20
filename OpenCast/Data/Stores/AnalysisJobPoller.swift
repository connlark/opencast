import Foundation

nonisolated struct AnalysisJobPoller<Response: Decodable & Sendable & Equatable>: Sendable {
    static var maximumPollAfter: TimeInterval { 120 }

    let timeout: Duration
    let sleep: @Sendable (Duration) async throws -> Void
    /// The job could not be read right now. A failed read is not proof the job failed, so these
    /// retry the same handle.
    let isTransientPollFailure: @Sendable (any Error) -> Bool
    let timedOutError: any Error
    /// 305 s in total: at least twice the ~2.5 min a reset job Durable Object stays unusable.
    var transientRetryDelays: [TimeInterval] = [5, 10, 20, 30, 60, 60, 60, 60]

    func pollUntilCompleted(
        jobID: String,
        initialPollAfter: TimeInterval,
        poll: @Sendable (String) async throws -> AnalysisJobPollOutcome<Response>
    ) async throws -> Response {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var pollAfter = Self.clampedPollAfter(initialPollAfter)
        var consecutiveTransientFailures = 0

        while true {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw timedOutError
            }

            let remaining = now.duration(to: deadline)
            let delay = min(Duration.seconds(pollAfter), remaining)
            if delay > .zero {
                try await sleep(delay)
            }
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw timedOutError
            }

            do {
                switch try await poll(jobID) {
                case .running(let nextPollAfter):
                    consecutiveTransientFailures = 0
                    pollAfter = Self.clampedPollAfter(nextPollAfter)
                case .completed(let response):
                    return response
                }
            } catch where isRetryablePollFailure(error) {
                guard consecutiveTransientFailures < transientRetryDelays.count else {
                    throw error
                }
                pollAfter = Self.clampedPollAfter(transientRetryDelays[consecutiveTransientFailures])
                consecutiveTransientFailures += 1
            }
        }
    }

    static func clampedPollAfter(_ value: TimeInterval) -> TimeInterval {
        min(max(value, 0), maximumPollAfter)
    }

    private func isRetryablePollFailure(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        return isTransientPollFailure(error)
    }
}
