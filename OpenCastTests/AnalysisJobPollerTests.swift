import Foundation
import Testing
@testable import OpenCast

@Suite("Analysis job poller")
struct AnalysisJobPollerTests {
    private struct TimedOut: Error {}
    private struct JobIDMismatch: Error {}
    private struct TransientFailure: Error {}
    private struct HardFailure: Error {}

    private actor StepCounter {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    @Test("Clamps poll-after into the 0...120 second window")
    func clampsPollAfter() {
        #expect(AnalysisJobPoller<String>.clampedPollAfter(-5) == 0)
        #expect(AnalysisJobPoller<String>.clampedPollAfter(30) == 30)
        #expect(AnalysisJobPoller<String>.clampedPollAfter(600) == 120)
    }

    @Test("Running polls continue until the job completes")
    func pollsUntilCompleted() async throws {
        let steps = StepCounter()

        let response = try await makePoller().pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { jobID in
                await steps.next() < 3 ? .running(pollAfter: 0) : .completed("done:\(jobID)")
            },
            resubmit: nil
        )

        #expect(response == "done:job")
        #expect(await steps.count == 3)
    }

    @Test("Three consecutive URL errors are tolerated and the fourth propagates")
    func toleratesThreeConsecutiveURLErrors() async throws {
        let recovering = StepCounter()
        let response = try await makePoller().pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { _ in
                if await recovering.next() <= 3 {
                    throw URLError(.networkConnectionLost)
                }
                return .completed("recovered")
            },
            resubmit: nil
        )
        #expect(response == "recovered")

        let failing = StepCounter()
        await #expect(throws: URLError.self) {
            try await makePoller().pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in
                    _ = await failing.next()
                    throw URLError(.timedOut)
                },
                resubmit: nil
            )
        }
        #expect(await failing.count == 4)
    }

    @Test("A successful poll resets the URL error streak")
    func successfulPollResetsURLErrorStreak() async throws {
        let steps = StepCounter()

        let response = try await makePoller().pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { _ in
                switch await steps.next() {
                case 1, 2, 3, 5, 6, 7:
                    throw URLError(.networkConnectionLost)
                case 4:
                    return .running(pollAfter: 0)
                default:
                    return .completed("done")
                }
            },
            resubmit: nil
        )

        #expect(response == "done")
        #expect(await steps.count == 8)
    }

    @Test("A transient failure resubmits once and a second one propagates")
    func transientFailureResubmitsOnce() async throws {
        let polls = StepCounter()
        let resubmits = StepCounter()

        let response = try await makePoller().pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { _ in
                if await polls.next() == 1 {
                    throw TransientFailure()
                }
                return .completed("after-resubmit")
            },
            resubmit: {
                _ = await resubmits.next()
                return .accepted(jobID: "job", pollAfter: 0)
            }
        )
        #expect(response == "after-resubmit")
        #expect(await resubmits.count == 1)

        let secondResubmits = StepCounter()
        await #expect(throws: TransientFailure.self) {
            try await makePoller().pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in throw TransientFailure() },
                resubmit: {
                    _ = await secondResubmits.next()
                    return .accepted(jobID: "job", pollAfter: 0)
                }
            )
        }
        #expect(await secondResubmits.count == 1)
    }

    @Test("A resubmit that completes synchronously returns its response")
    func resubmitCompletingSynchronouslyReturnsResponse() async throws {
        let response = try await makePoller().pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { _ in throw TransientFailure() },
            resubmit: { .completed("synchronous") }
        )

        #expect(response == "synchronous")
    }

    @Test("A transient failure with no resubmit path propagates")
    func transientFailureWithoutResubmitPropagates() async {
        await #expect(throws: TransientFailure.self) {
            try await makePoller().pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in throw TransientFailure() },
                resubmit: nil
            )
        }
    }

    @Test("Non-transient failures propagate without a resubmit")
    func hardFailurePropagates() async {
        let resubmits = StepCounter()

        await #expect(throws: HardFailure.self) {
            try await makePoller().pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in throw HardFailure() },
                resubmit: {
                    _ = await resubmits.next()
                    return .accepted(jobID: "job", pollAfter: 0)
                }
            )
        }
        #expect(await resubmits.count == 0)
    }

    @Test("A resubmit that changes the job ID is a mismatch")
    func resubmitJobIDMismatch() async {
        await #expect(throws: JobIDMismatch.self) {
            try await makePoller().pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in throw TransientFailure() },
                resubmit: { .accepted(jobID: "other-job", pollAfter: 0) }
            )
        }
    }

    @Test("The deadline surfaces the caller's timed-out error before any poll")
    func deadlineSurfacesTimedOutError() async {
        let polls = StepCounter()

        await #expect(throws: TimedOut.self) {
            try await makePoller(timeout: .zero).pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in
                    _ = await polls.next()
                    return .running(pollAfter: 0)
                },
                resubmit: nil
            )
        }
        #expect(await polls.count == 0)
    }

    @Test("Cancellation ends the loop with a cancellation error")
    func cancellationEndsLoop() async {
        let poller = makePoller()
        let task = Task {
            try await poller.pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in .running(pollAfter: 0) },
                resubmit: nil
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func makePoller(timeout: Duration = .seconds(30)) -> AnalysisJobPoller<String> {
        AnalysisJobPoller(
            timeout: timeout,
            sleep: { _ in },
            isTransientJobFailure: { $0 is TransientFailure },
            timedOutError: TimedOut(),
            jobIDMismatchError: JobIDMismatch()
        )
    }
}
