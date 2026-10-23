import Foundation
import Testing
@testable import OpenCast

@Suite("Analysis job poller")
struct AnalysisJobPollerTests {
    private struct TimedOut: Error {}
    private struct JobIDMismatch: Error {}
    private struct TransientFailure: Error {}
    private struct UnavailableFailure: Error {}
    private struct HardFailure: Error {}

    private static let ladder: [Duration] = [5, 10, 20, 30, 60, 60, 60, 60].map { Duration.seconds($0) }

    private actor StepCounter {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    private actor SleepRecorder {
        private(set) var durations: [Duration] = []

        func record(_ duration: Duration) {
            durations.append(duration)
        }
    }

    /// Opens once the poller parks in a retry-ladder sleep.
    private actor SleepGate {
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func enter() {
            entered = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { waiters.append($0) }
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

    @Test("URL errors walk the retry ladder and the ninth consecutive one propagates")
    func urlErrorsWalkRetryLadder() async throws {
        let recovering = StepCounter()
        let recoveringSleeps = SleepRecorder()
        let response = try await makePoller(
            timeout: .seconds(1_800),
            sleep: { await recoveringSleeps.record($0) }
        ).pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { _ in
                if await recovering.next() <= 8 {
                    throw URLError(.networkConnectionLost)
                }
                return .completed("recovered")
            },
            resubmit: nil
        )
        #expect(response == "recovered")
        #expect(await recoveringSleeps.durations == Self.ladder)

        let failing = StepCounter()
        let failingSleeps = SleepRecorder()
        await #expect(throws: URLError.self) {
            try await makePoller(
                timeout: .seconds(1_800),
                sleep: { await failingSleeps.record($0) }
            ).pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in
                    _ = await failing.next()
                    throw URLError(.timedOut)
                },
                resubmit: nil
            )
        }
        #expect(await failing.count == 9)
        #expect(await failingSleeps.durations == Self.ladder)
    }

    @Test("Transient poll failures share the URL error streak and an exhausted ladder never resubmits")
    func transientPollFailuresShareStreakWithoutResubmit() async {
        let polls = StepCounter()
        let resubmits = StepCounter()
        let sleeps = SleepRecorder()
        // Even an error the resubmit rule would also accept stays on the
        // ladder: a failed read must never buy another model run.
        let poller = AnalysisJobPoller<String>(
            timeout: .seconds(1_800),
            sleep: { await sleeps.record($0) },
            isTransientJobFailure: { $0 is UnavailableFailure },
            isTransientPollFailure: { $0 is UnavailableFailure },
            timedOutError: TimedOut(),
            jobIDMismatchError: JobIDMismatch()
        )

        await #expect(throws: UnavailableFailure.self) {
            try await poller.pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in
                    if await polls.next().isMultiple(of: 2) {
                        throw URLError(.networkConnectionLost)
                    }
                    throw UnavailableFailure()
                },
                resubmit: {
                    _ = await resubmits.next()
                    return .accepted(jobID: "job", pollAfter: 0)
                }
            )
        }
        #expect(await polls.count == 9)
        #expect(await resubmits.count == 0)
        #expect(await sleeps.durations == Self.ladder)
    }

    @Test("A running poll resets the ladder to its first step")
    func runningPollResetsLadder() async throws {
        let steps = StepCounter()
        let sleeps = SleepRecorder()

        let response = try await makePoller(
            timeout: .seconds(1_800),
            sleep: { await sleeps.record($0) }
        ).pollUntilCompleted(
            jobID: "job",
            initialPollAfter: 0,
            poll: { _ in
                switch await steps.next() {
                case 1...3, 5...12:
                    throw UnavailableFailure()
                case 4:
                    return .running(pollAfter: 15)
                default:
                    return .completed("done")
                }
            },
            resubmit: nil
        )

        #expect(response == "done")
        #expect(await steps.count == 13)
        #expect(await sleeps.durations == Array(Self.ladder.prefix(3)) + [.seconds(15)] + Self.ladder)
    }

    @Test("Cancellation inside a retry-ladder sleep rethrows promptly")
    func cancellationInsideLadderRethrows() async {
        let gate = SleepGate()
        let poller = makePoller(timeout: .seconds(1_800)) { _ in
            await gate.enter()
            try await Task.sleep(for: .seconds(3_600))
        }
        let task = Task {
            try await poller.pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in throw UnavailableFailure() },
                resubmit: nil
            )
        }
        await gate.waitUntilEntered()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("A cancelled URL request propagates without entering the ladder")
    func cancelledURLRequestSkipsLadder() async {
        let polls = StepCounter()
        let sleeps = SleepRecorder()

        await #expect(throws: URLError.self) {
            try await makePoller(sleep: { await sleeps.record($0) }).pollUntilCompleted(
                jobID: "job",
                initialPollAfter: 0,
                poll: { _ in
                    _ = await polls.next()
                    throw URLError(.cancelled)
                },
                resubmit: nil
            )
        }
        #expect(await polls.count == 1)
        #expect(await sleeps.durations.isEmpty)
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

    private func makePoller(
        timeout: Duration = .seconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> AnalysisJobPoller<String> {
        AnalysisJobPoller(
            timeout: timeout,
            sleep: sleep,
            isTransientJobFailure: { $0 is TransientFailure },
            isTransientPollFailure: { $0 is UnavailableFailure },
            timedOutError: TimedOut(),
            jobIDMismatchError: JobIDMismatch()
        )
    }
}
