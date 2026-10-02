import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Sync status account patience")
struct SyncStatusStoreAccountPatienceTests {
    @Test("An account check that has not answered is not waited for past the patience")
    func unansweredCheckStopsBeingWaitedFor() async {
        let gate = AsyncTestGate()
        let store = SyncStatusStore(
            accountStatusProvider: GatedCloudKitAccountStatusProvider(gate: gate, status: .available),
            accountStatusPatience: .milliseconds(50)
        )

        let statusAtTimeout = await store.refreshAccountStatusWithinPatience(force: true)

        // The caller moves on with what is known; the check itself is still
        // running and publishes its answer when it arrives.
        #expect(statusAtTimeout == .checking)
        #expect(store.accountStatus == .checking)

        await gate.release()
        let answered = await store.refreshAccountStatus()
        #expect(answered == .available)
        #expect(store.accountStatus == .available)
    }

    @Test("A prompt answer is returned without waiting out the patience")
    func promptAnswerReturnsImmediately() async {
        let store = SyncStatusStore(
            accountStatusProvider: AvailableCloudKitAccountStatusProvider(),
            accountStatusPatience: .seconds(600)
        )

        let clock = ContinuousClock()
        let started = clock.now
        let status = await store.refreshAccountStatusWithinPatience(force: true)

        #expect(status == .available)
        #expect(started.duration(to: clock.now) < .seconds(60))
    }

    @Test("A bounded wait joins a check that is already running")
    func boundedWaitJoinsTheRunningCheck() async {
        let gate = AsyncTestGate()
        let provider = GatedCloudKitAccountStatusProvider(gate: gate, status: .noAccount)
        let store = SyncStatusStore(
            accountStatusProvider: provider,
            accountStatusPatience: .seconds(600)
        )

        let forced = Task { await store.refreshAccountStatus(force: true) }
        let bounded = Task { await store.refreshAccountStatusWithinPatience() }
        await gate.release()

        #expect(await forced.value == .noAccount)
        #expect(await bounded.value == .noAccount)
        #expect(await provider.callCount == 1)
    }

    @Test("A recently refreshed status is returned without another check")
    func recentStatusSkipsTheCheck() async {
        let gate = AsyncTestGate()
        await gate.release()
        let provider = GatedCloudKitAccountStatusProvider(gate: gate, status: .available)
        let store = SyncStatusStore(
            accountStatusProvider: provider,
            now: { Date(timeIntervalSinceReferenceDate: 0) }
        )

        await store.refreshAccountStatus()
        let status = await store.refreshAccountStatusWithinPatience()

        #expect(status == .available)
        #expect(await provider.callCount == 1)
    }
}

private actor GatedCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    private let gate: AsyncTestGate
    private let status: SyncAccountStatus
    private(set) var callCount = 0

    init(gate: AsyncTestGate, status: SyncAccountStatus) {
        self.gate = gate
        self.status = status
    }

    func accountStatus() async throws -> SyncAccountStatus {
        callCount += 1
        await gate.wait()
        return status
    }
}
