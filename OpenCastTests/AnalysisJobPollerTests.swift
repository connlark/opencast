import Foundation
import Testing
@testable import OpenCast

@Suite("Analysis job poller")
struct AnalysisJobPollerTests {
    private struct TimedOut: Error {}
    private struct UnavailableFailure: Error {}

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

    @Test("Transient poll failures share the URL error streak until the ladder is exhausted")
    func transientPollFailuresShareStreak() async {
        let polls = StepCounter()
        let sleeps = SleepRecorder()
        let poller = AnalysisJobPoller<String>(
            timeout: .seconds(1_800),
            sleep: { await sleeps.record($0) },
            isTransientPollFailure: { $0 is UnavailableFailure },
            timedOutError: TimedOut()
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
                }
            )
        }
        #expect(await polls.count == 9)
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
            }
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
                poll: { _ in throw UnavailableFailure() }
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
                }
            )
        }
        #expect(await polls.count == 1)
        #expect(await sleeps.durations.isEmpty)
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
                }
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
                poll: { _ in .running(pollAfter: 0) }
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
            isTransientPollFailure: { $0 is UnavailableFailure },
            timedOutError: TimedOut()
        )
    }
}
