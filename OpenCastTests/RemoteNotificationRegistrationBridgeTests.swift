import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("APNs registration bridge")
struct RemoteNotificationRegistrationBridgeTests {
    @Test("Concurrent registration callers share one APNs request")
    func concurrentRequests() async throws {
        var requests = 0
        let bridge = RemoteNotificationRegistrationBridge { requests += 1 }
        var started = 0
        let first = Task { started += 1; return try await bridge.registerForRemoteNotifications() }
        let second = Task { started += 1; return try await bridge.registerForRemoteNotifications() }
        while started < 2 { await Task.yield() }
        #expect(requests == 1)
        let token = Data([1, 2, 3])
        #expect(bridge.didRegister(deviceToken: token))
        #expect(try await first.value == token)
        #expect(try await second.value == token)
        #expect(!bridge.didRegister(deviceToken: Data([4, 5, 6])))
    }

    @Test("Cancelling one waiter does not cancel the other registration")
    func independentCancellation() async throws {
        let bridge = RemoteNotificationRegistrationBridge {}
        var started = 0
        let first = Task { started += 1; return try await bridge.registerForRemoteNotifications() }
        let second = Task { started += 1; return try await bridge.registerForRemoteNotifications() }
        while started < 2 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let token = Data([7])
        #expect(bridge.didRegister(deviceToken: token))
        #expect(try await second.value == token)
    }
}
