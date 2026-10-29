import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Synchronization
import Testing

@MainActor
final class FakeContinuedTaskHandle: AnalysisContinuedTaskHandle {
    let progress = Progress(totalUnitCount: 0)
    private(set) var titles: [(String, String)] = []
    private(set) var completions: [Bool] = []
    private(set) var expirationHandler: (@Sendable () -> Void)?

    func updateTitle(_ title: String, subtitle: String) { titles.append((title, subtitle)) }
    func setTaskCompleted(success: Bool) { completions.append(success) }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) { expirationHandler = handler }
}

@MainActor
final class FakeContinuedTaskScheduler: AnalysisContinuedTaskScheduling {
    var registers = true
    var submitError: (any Error)?
    /// When set, submissions wait for it.
    var submitGate: HoldGate?
    private(set) var launchHandler: (@MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void)?
    private(set) var submitted: [(String, String, String)] = []
    private(set) var cancelled: [String] = []

    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> Bool {
        launchHandler = onLaunch
        return registers
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {
        if let submitGate { await submitGate.wait() }
        if let submitError { throw submitError }
        submitted.append((identifier, title, subtitle))
    }

    func cancel(identifier: String) { cancelled.append(identifier) }

    func launch(_ handle: FakeContinuedTaskHandle) { launchHandler?(handle) }
}

@MainActor
final class FakeArbiter: AnalysisContinuedTaskArbiter {
    var allows = true
    func mayArm(identifier: String) -> Bool { allows }
}

/// A run the test finishes by hand.
final class Gate: Sendable {
    private let stream: AsyncStream<AnalysisOutcome>
    private let continuation: AsyncStream<AnalysisOutcome>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: AnalysisOutcome.self)
    }

    func open(_ outcome: AnalysisOutcome) { continuation.yield(outcome) }

    func wait() async -> AnalysisOutcome {
        for await outcome in stream { return outcome }
        return .failed(AnalysisFailure(feature: .chaptersSummary, code: .cancelled, status: 503))
    }
}

/// Holds its waiters until the test opens it. Unlike ``Gate`` it ignores
/// cancellation, so a waiter cannot leave early.
final class HoldGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var waiting: Bool { state.withLock { !$0.waiters.isEmpty } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A flag one task sets and another reads.
final class Flag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

@MainActor
@Suite("Execution session")
struct AnalysisExecutionSessionTests {
    nonisolated static let identifier = "test.chapters"
    nonisolated static let success = AnalysisOutcome.chaptersSummary(TranscriptAnalysisResponse(
        schemaVersion: 1, requestID: "r", model: "m", policy: "p", chapters: [], summary: nil, warnings: [], usage: nil
    ))
    nonisolated static let cancelled = AnalysisOutcome.failed(AnalysisFailure(feature: .chaptersSummary, code: .cancelled, status: 503))

    func session(_ scheduler: FakeContinuedTaskScheduler, arbiter: FakeArbiter? = FakeArbiter(), clock: ManualClock = ManualClock(), tick: Duration = .seconds(2)) -> AnalysisExecutionSession {
        AnalysisExecutionSession(identifier: Self.identifier, title: "Generating Chapters", scheduler: scheduler, arbiter: arbiter, tickInterval: tick, clock: clock)
    }

    @Test("A launched card ticks forward every interval and completes at the total on success")
    func ticksAndCompletes() async {
        let scheduler = FakeContinuedTaskScheduler()
        let clock = ManualClock()
        let session = session(scheduler, clock: clock)
        let gate = Gate()
        let running = Task { await session.run(subtitle: "Episode", expectedSeconds: 100) { await gate.wait() } }
        #expect(await eventually { session.state == .submitted })
        #expect(scheduler.submitted.map(\.0) == [Self.identifier])

        let handle = FakeContinuedTaskHandle()
        scheduler.launch(handle)
        #expect(session.state == .running)
        #expect(session.isProtectingBackgroundExecution)
        #expect(handle.progress.totalUnitCount == 1_000)
        #expect(handle.titles.first?.0 == "Generating Chapters")
        var previous = handle.progress.completedUnitCount
        for _ in 0..<60 {
            await clock.waitForSleepers()
            clock.advance(by: 2)
            #expect(await eventually { handle.progress.completedUnitCount > previous })
            previous = handle.progress.completedUnitCount
        }
        #expect(previous < 1_000)

        gate.open(Self.success)
        #expect(await running.value == .finished(Self.success, background: true))
        #expect(handle.completions == [true])
        #expect(handle.progress.completedUnitCount == 1_000)
        #expect(session.state == .idle)
    }

    @Test("Progress keeps moving past the expected time, one short of the total at most")
    func creepNeverStalls() async {
        let scheduler = FakeContinuedTaskScheduler()
        let clock = ManualClock()
        let session = session(scheduler, clock: clock, tick: .seconds(30))
        let gate = Gate()
        let running = Task { await session.run(subtitle: "E", expectedSeconds: 30) { await gate.wait() } }
        #expect(await eventually { session.state == .submitted })
        let handle = FakeContinuedTaskHandle()
        scheduler.launch(handle)
        var previous = handle.progress.completedUnitCount
        for _ in 0..<5 {
            await clock.waitForSleepers()
            clock.advance(by: 30)
            #expect(await eventually { handle.progress.completedUnitCount > previous })
            previous = handle.progress.completedUnitCount
        }
        #expect(previous <= 999)
        gate.open(.failed(AnalysisFailure(feature: .chaptersSummary, code: .invalidModelOutput, status: 502)))
        _ = await running.value
        #expect(handle.completions == [false])
    }

    @Test("Ticks are never more than a minute apart")
    func tickCap() async {
        let scheduler = FakeContinuedTaskScheduler()
        let clock = ManualClock()
        let session = session(scheduler, clock: clock, tick: .seconds(600))
        let gate = Gate()
        let running = Task { await session.run(subtitle: "E", expectedSeconds: 540) { await gate.wait() } }
        #expect(await eventually { session.state == .submitted })
        let handle = FakeContinuedTaskHandle()
        scheduler.launch(handle)
        let before = handle.progress.completedUnitCount
        await clock.waitForSleepers()
        clock.advance(by: 60)
        #expect(await eventually { handle.progress.completedUnitCount > before })
        gate.open(Self.success)
        _ = await running.value
    }

    @Test("Expiration cancels the run and ends the card unsuccessfully")
    func expiration() async {
        let scheduler = FakeContinuedTaskScheduler()
        let session = session(scheduler)
        let running = Task {
            await session.run(subtitle: "E", expectedSeconds: 100) {
                while !Task.isCancelled { await Task.yield() }
                return Self.cancelled
            }
        }
        #expect(await eventually { session.state == .submitted })
        let handle = FakeContinuedTaskHandle()
        scheduler.launch(handle)
        handle.expirationHandler?()
        #expect(await running.value == .expired)
        #expect(handle.completions == [false])
        #expect(session.state == .idle)
    }

    @Test("The arbiter's refusal runs the work foreground-only with no submission")
    func arbiterRefuses() async {
        let scheduler = FakeContinuedTaskScheduler()
        let arbiter = FakeArbiter()
        arbiter.allows = false
        let session = session(scheduler, arbiter: arbiter)
        let result = await session.run(subtitle: "E", expectedSeconds: 10) { Self.success }
        #expect(result == .finished(Self.success, background: false))
        #expect(scheduler.submitted.isEmpty)
    }

    @Test("A refused registration or submission runs the work foreground-only")
    func schedulerRefuses() async {
        let unregistered = FakeContinuedTaskScheduler()
        unregistered.registers = false
        #expect(await session(unregistered).run(subtitle: "E", expectedSeconds: 10) { Self.success } == .finished(Self.success, background: false))
        #expect(unregistered.submitted.isEmpty)

        struct Refused: Error {}
        let refusing = FakeContinuedTaskScheduler()
        refusing.submitError = Refused()
        #expect(await session(refusing).run(subtitle: "E", expectedSeconds: 10) { Self.success } == .finished(Self.success, background: false))
    }

    @Test("Work that ends before the system launches the card withdraws the request; a late launch is ended at once")
    func finishesBeforeLaunch() async {
        let scheduler = FakeContinuedTaskScheduler()
        let session = session(scheduler)
        let result = await session.run(subtitle: "E", expectedSeconds: 10) { Self.success }
        #expect(result == .finished(Self.success, background: false))
        #expect(scheduler.cancelled.filter { $0 == Self.identifier }.count == 2)
        let late = FakeContinuedTaskHandle()
        scheduler.launch(late)
        #expect(late.completions == [false])
    }

    @Test("Cancelling the caller cancels the work")
    func callerCancellation() async {
        let scheduler = FakeContinuedTaskScheduler()
        let session = session(scheduler)
        let running = Task {
            await session.run(subtitle: "E", expectedSeconds: 100) {
                while !Task.isCancelled { await Task.yield() }
                return Self.cancelled
            }
        }
        #expect(await eventually { session.state == .submitted })
        running.cancel()
        #expect(await running.value == .finished(Self.cancelled, background: false))
    }

    @Test("Cancelling the caller while the card is still being submitted cancels the work at once")
    func cancellationDuringSubmission() async {
        let scheduler = FakeContinuedTaskScheduler()
        // Submission stays held until the test opens it, cancelled or not.
        let hold = HoldGate()
        scheduler.submitGate = hold
        let session = session(scheduler)
        let observed = Flag()
        let running = Task {
            await session.run(subtitle: "E", expectedSeconds: 100) {
                while !Task.isCancelled { await Task.yield() }
                observed.set()
                return Self.cancelled
            }
        }
        #expect(await eventually { hold.waiting })
        running.cancel()
        #expect(await eventually(within: 60) { observed.isSet }, "the work did not see the cancellation while submission was held")
        #expect(hold.waiting)
        hold.open()
        #expect(await running.value == .finished(Self.cancelled, background: false))
    }

    @Test("Progress moves on every tick through twice the expected run, whatever the tick")
    func progressCapacity() {
        for (expected, tick) in [(540.0, 0.1), (540.0, 2.0), (30.0, 60.0), (100.0, 2.0), (1.0, 0.1)] {
            let scale = AnalysisExecutionSession.ProgressScale(expectedSeconds: expected, tickSeconds: tick)
            var units = scale.start
            let ticks = Int((2 * expected / tick).rounded(.up))
            for index in 1...ticks {
                let next = scale.units(after: Double(index) * tick, previous: units)
                #expect(next > units, "expected \(expected) tick \(tick) at \(index)")
                units = next
            }
            #expect(units < scale.total)
        }
    }
}

extension AnalysisExecutionSessionTests {
    @Test("A huge expected run time neither traps nor stalls the card")
    func hugeExpectedRun() {
        let scale = AnalysisExecutionSession.ProgressScale(expectedSeconds: 1e19, tickSeconds: 0.1)
        #expect(scale.total > 0 && scale.start < scale.ceiling && scale.ceiling < scale.total)
        #expect(scale.units(after: 1, previous: scale.start) > scale.start)
        let infinite = AnalysisExecutionSession.ProgressScale(expectedSeconds: .infinity, tickSeconds: 2)
        #expect(infinite.units(after: 10, previous: infinite.start) > infinite.start)
    }
}
