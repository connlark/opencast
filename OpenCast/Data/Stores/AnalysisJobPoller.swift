import Foundation

/// Drives one accepted analysis job to completion for the ad and transcript
/// analysis stores: bounded by `timeout`, walking a same-handle retry ladder
/// through transient read failures, and allowed a single resubmit when the
/// worker reports the job lost. Pure — no SwiftData and no store state — so
/// the loop is testable without a store.
nonisolated struct AnalysisJobPoller<Response: Decodable & Sendable & Equatable>: Sendable {
    static var maximumPollAfter: TimeInterval { 120 }

    let timeout: Duration
    let sleep: @Sendable (Duration) async throws -> Void
    /// Worker errors meaning "the job is gone, submit it again". Honoured
    /// once per run, and only when the caller can resubmit.
    let isTransientJobFailure: @Sendable (any Error) -> Bool
    /// Worker errors meaning "the job could not be read right now" (an
    /// unavailable job object, an untyped 5xx). A failed read is not proof
    /// the job failed, so these walk `transientRetryDelays` on the same
    /// handle and never resubmit. Transport errors other than cancellation
    /// always qualify.
    let isTransientPollFailure: @Sendable (any Error) -> Bool
    let timedOutError: any Error
    let jobIDMismatchError: any Error
    var jobIDsMatch: @Sendable (String, String) -> Bool = { $0 == $1 }
    /// Waits before each retry of a consecutive transient-failure streak; the
    /// failure after the last one propagates. 305 s in total, at least twice
    /// the ~2.5 min a reset job Durable Object stayed unusable on 2026-10-23,
    /// and still clamped by the overall deadline.
    var transientRetryDelays: [TimeInterval] = [5, 10, 20, 30, 60, 60, 60, 60]

    func pollUntilCompleted(
        jobID: String,
        initialPollAfter: TimeInterval,
        poll: @Sendable (String) async throws -> AnalysisJobPollOutcome<Response>,
        resubmit: (@Sendable () async throws -> AnalysisJobSubmitOutcome<Response>)?
    ) async throws -> Response {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var activeJobID = jobID
        var pollAfter = Self.clampedPollAfter(initialPollAfter)
        var didResubmit = false
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
                switch try await poll(activeJobID) {
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
            } catch where isTransientJobFailure(error) && !didResubmit && resubmit != nil {
                didResubmit = true
                consecutiveTransientFailures = 0
                guard let resubmit else {
                    throw error
                }
                switch try await resubmit() {
                case .completed(let response):
                    return response
                case .accepted(let resubmittedJobID, let nextPollAfter):
                    guard jobIDsMatch(resubmittedJobID, jobID) else {
                        throw jobIDMismatchError
                    }
                    activeJobID = resubmittedJobID
                    pollAfter = Self.clampedPollAfter(nextPollAfter)
                }
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
