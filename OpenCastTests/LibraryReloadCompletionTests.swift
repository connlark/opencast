import Foundation
import Testing
@testable import OpenCast

@MainActor
struct LibraryReloadCompletionTests {
    @Test func claimedReplacementSuspendsOtherWaitersBeforeBeginning() async throws {
        let completion = LibraryReloadCompletion()
        completion.begin(1)
        completion.finishCancelled(1)
        #expect(completion.claimReplacement(for: 1))
        #expect(!completion.claimReplacement(for: 1))
        let cancelled = Task { try await completion.waitForCurrent() }
        let surviving = Task { try await completion.waitForCurrent() }
        defer { cancelled.cancel(); surviving.cancel() }
        try await waitForWaiters(2, in: completion)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(completion.waiterCount == 1)

        completion.begin(2)
        completion.finishPublished(1)
        #expect(completion.waiterCount == 1)
        completion.finishPublished(2)
        guard case .published = try await surviving.value else {
            Issue.record("The surviving caller did not wait for replacement publication")
            return
        }
        #expect(completion.waiterCount == 0)
    }

    @Test(arguments: [false, true])
    func claimedReplacementWaitersObserveFailureOrInvalidation(invalidate: Bool) async throws {
        let completion = LibraryReloadCompletion()
        completion.begin(1)
        completion.finishCancelled(1)
        #expect(completion.claimReplacement(for: 1))
        let waiter = Task { try await completion.waitForCurrent() }
        defer { waiter.cancel() }
        try await waitForWaiters(1, in: completion)
        if invalidate {
            completion.invalidate(2)
            guard case .invalidated = try await waiter.value else {
                Issue.record("A claimed replacement must not revive an invalidated library")
                return
            }
        } else {
            completion.begin(2)
            let failure = CocoaError(.fileReadCorruptFile)
            completion.finishFailed(2, error: failure)
            await #expect(throws: failure) { _ = try await waiter.value }
        }
        #expect(completion.waiterCount == 0)
    }

    private func waitForWaiters(_ count: Int, in completion: LibraryReloadCompletion) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while completion.waiterCount != count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(completion.waiterCount == count, "Waiters must suspend during the claim/begin gap")
    }
}
