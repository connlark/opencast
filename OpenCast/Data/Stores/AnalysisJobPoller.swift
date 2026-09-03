import Foundation

/// Drives one accepted analysis job to completion for the ad and transcript
/// analysis stores: bounded by `timeout`, tolerant of three consecutive
/// transport errors, and allowed a single resubmit when the worker reports
/// the job lost. Pure — no SwiftData and no store state — so the loop is
/// testable without a store.
nonisolated struct AnalysisJobPoller<Response: Decodable & Sendable & Equatable>: Sendable {
    static var maximumPollAfter: TimeInterval { 120 }
    static var tolerableConsecutiveURLErrors: Int { 3 }

    let timeout: Duration
    let sleep: @Sendable (Duration) async throws -> Void
    /// Worker errors meaning "the job is gone, submit it again". Honoured
    /// once per run, and only when the caller can resubmit.
    let isTransientJobFailure: @Sendable (any Error) -> Bool
    let timedOutError: any Error
    let jobIDMismatchError: any Error

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
        var consecutiveURLErrors = 0

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
                    consecutiveURLErrors = 0
                    pollAfter = Self.clampedPollAfter(nextPollAfter)
                case .completed(let response):
                    return response
                }
            } catch let error as URLError {
                consecutiveURLErrors += 1
                guard consecutiveURLErrors <= Self.tolerableConsecutiveURLErrors else {
                    throw error
                }
            } catch where isTransientJobFailure(error) && !didResubmit && resubmit != nil {
                didResubmit = true
                consecutiveURLErrors = 0
                guard let resubmit else {
                    throw error
                }
                switch try await resubmit() {
                case .completed(let response):
                    return response
                case .accepted(let resubmittedJobID, let nextPollAfter):
                    guard resubmittedJobID == jobID else {
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
}
