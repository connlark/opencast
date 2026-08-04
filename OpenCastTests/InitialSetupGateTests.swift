import Testing
@testable import OpenCast

@MainActor
struct InitialSetupGateTests {
    @Test("Completing setup releases every waiter")
    func completionReleasesAllWaiters() async {
        let gate = InitialSetupGate()
        let first = Task { await gate.wait() }
        let second = Task { await gate.wait() }
        await waitUntil { gate.waiterCount == 2 }

        gate.complete()
        await first.value
        await second.value

        #expect(gate.isComplete)
        #expect(gate.waiterCount == 0)
    }

    @Test("Cancelling a setup waiter removes it without completing the gate")
    func cancellationRemovesWaiter() async {
        let gate = InitialSetupGate()
        let task = Task { await gate.wait() }
        await waitUntil { gate.waiterCount == 1 }

        task.cancel()
        await task.value

        #expect(!gate.isComplete)
        #expect(gate.waiterCount == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }
}
