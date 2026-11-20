import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

@Suite("Key pacing")
struct AnalysisKeyPacerTests {
    /// Starts `count` admissions and returns their tasks.
    func admissions(_ pacer: AnalysisKeyPacer, count: Int, deadline: Double = 1_000) -> [Task<AnalysisPacerAdmission, Never>] {
        (0..<count).map { _ in Task { await pacer.admit(deadline: deadline) } }
    }

    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test("Up to max_in_flight run at once before any rate limit; the next waits for a release")
    func concurrentUntilLimit() async {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 4, clock: clock)
        let first = admissions(pacer, count: 4)
        for task in first { #expect(await task.value == .admitted(waitedSeconds: 0)) }
        let fifth = Task { await pacer.admit(deadline: 1_000) }
        await clock.waitForSleepers()
        clock.advance(by: 3)
        await pacer.release()
        #expect(await fifth.value == .admitted(waitedSeconds: 3))
    }

    @Test("After a rate limit the key runs serially and waits out Retry-After")
    func serialAfterRateLimit() async {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 4, clock: clock)
        #expect(await pacer.admit(deadline: 1_000) == .admitted(waitedSeconds: 0))
        await pacer.noteRateLimited(retryAfterSeconds: 5)
        await pacer.release()
        #expect(await pacer.isSerial)
        #expect(await pacer.admissionLimit == 1)

        let next = Task { await pacer.admit(deadline: 1_000) }
        await clock.waitForSleepers()
        clock.advance(by: 4)
        await settle()
        #expect(clock.sleeperCount == 1)
        clock.advance(by: 1)
        #expect(await next.value == .admitted(waitedSeconds: 5))

        let waiting = Task { await pacer.admit(deadline: 1_000) }
        await clock.waitForSleepers()
        clock.advance(by: 2)
        await pacer.release()
        #expect(await waiting.value == .admitted(waitedSeconds: 2))
    }

    @Test("A rate limit without Retry-After serialises without a pause")
    func serialWithoutRetryAfter() async {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 2, clock: clock)
        await pacer.noteRateLimited(retryAfterSeconds: nil)
        #expect(await pacer.admit(deadline: 10) == .admitted(waitedSeconds: 0))
        let second = Task { await pacer.admit(deadline: 10) }
        await clock.waitForSleepers()
        await pacer.release()
        #expect(await second.value == .admitted(waitedSeconds: 0))
    }

    @Test("A request that cannot be admitted before its deadline is refused")
    func deadlines() async {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
        #expect(await pacer.admit(deadline: 100) == .admitted(waitedSeconds: 0))
        let blocked = Task { await pacer.admit(deadline: 30) }
        await clock.waitForSleepers()
        clock.advance(by: 30)
        #expect(await blocked.value == .deadlinePassed)
        await pacer.release()

        await pacer.noteRateLimited(retryAfterSeconds: 20)
        #expect(await pacer.admit(deadline: clock.now() + 10) == .deadlinePassed)
        #expect(await pacer.admit(deadline: clock.now()) == .deadlinePassed)
    }

    @Test("Cancelling a waiting request withdraws it")
    func cancellation() async {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
        _ = await pacer.admit(deadline: 100)
        let waiting = Task { await pacer.admit(deadline: 100) }
        await clock.waitForSleepers()
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        await pacer.release()
        #expect(await pacer.admit(deadline: 100) == .admitted(waitedSeconds: 0))
    }

    @Test("One pacer per key for the session; other keys are independent")
    func registry() async {
        let pacing = AnalysisKeyPacing(clock: ManualClock())
        let a = pacing.pacer(provider: .google, key: ProviderTestKeys.google, maxInFlight: 4)
        let b = pacing.pacer(provider: .google, key: AnalysisProviderKey(ProviderTestKeys.googleText + " ")!, maxInFlight: 2)
        let other = pacing.pacer(provider: .openai, key: ProviderTestKeys.openAI, maxInFlight: 4)
        #expect(a === b)
        #expect(a !== other)
        #expect(b.maxInFlight == 4)
    }

    @Test("A woken request that leaves without the slot wakes the next one")
    func leavingPassesTheWakeUpOn() async {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
        #expect(await pacer.admit(deadline: 100) == .admitted(waitedSeconds: 0))
        await pacer.noteRateLimited(retryAfterSeconds: 20)
        let early = Task { await pacer.admit(deadline: 10) }
        await clock.waitForSleepers(1)
        let late = Task { await pacer.admit(deadline: 100) }
        await clock.waitForSleepers(2)
        await pacer.release()
        #expect(await early.value == .deadlinePassed)
        // Without the hand-off the late request sleeps on to its own
        // deadline and is refused there.
        let handedOff = await eventually { clock.wakeTimes == [20] }
        #expect(handedOff)
        clock.advance(by: handedOff ? 20 : 100)
        #expect(await late.value == .admitted(waitedSeconds: 20))
    }
}
