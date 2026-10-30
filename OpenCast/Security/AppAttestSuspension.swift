import Foundation
import Synchronization

/// Closes admission during Delete Data and drains registrations before a slot
/// is deleted. Existing sections may finish, including nested recovery work.
nonisolated final class AppAttestSuspension: Sendable {
    static let shared = AppAttestSuspension()

    private struct State {
        var suspended = false
        var sections: [String: Set<UUID>] = [:]
        var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    }

    @TaskLocal private static var sectionIDs: [String: UUID] = [:]
    private let state = Mutex(State())

    var isSuspended: Bool { state.withLock { $0.suspended } }

    func suspend() { state.withLock { $0.suspended = true } }
    func resume() { state.withLock { $0.suspended = false } }

    func checkAdmission() throws {
        if isSuspended { throw AppAttestSuspendedError() }
    }

    func withRegistrationSection<Value>(
        keychainService: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let inheritedID = Self.sectionIDs[keychainService]
        let id = UUID()
        let nested = try state.withLock { state in
            if let inheritedID, state.sections[keychainService]?.contains(inheritedID) == true {
                return true
            }
            guard !state.suspended else { throw AppAttestSuspendedError() }
            state.sections[keychainService, default: []].insert(id)
            return false
        }
        if nested { return try await operation() }
        defer { endSection(keychainService: keychainService, id: id) }
        var sectionIDs = Self.sectionIDs
        sectionIDs[keychainService] = id
        return try await Self.$sectionIDs.withValue(sectionIDs, operation: operation)
    }

    func drain(keychainService: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let drained = state.withLock { state in
                    guard !Task.isCancelled,
                          state.sections[keychainService]?.isEmpty == false else { return true }
                    state.waiters[keychainService, default: [:]][id] = continuation
                    return false
                }
                if drained { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.state.withLock { state in
                let waiter = state.waiters[keychainService]?.removeValue(forKey: id)
                if state.waiters[keychainService]?.isEmpty == true {
                    state.waiters[keychainService] = nil
                }
                return waiter
            }
            waiter?.resume()
        }
    }

    func drainWaiterCount(keychainService: String) -> Int {
        state.withLock { $0.waiters[keychainService]?.count ?? 0 }
    }

    func hasRegistrationSection(keychainService: String) -> Bool {
        state.withLock { $0.sections[keychainService]?.isEmpty == false }
    }

    private func endSection(keychainService: String, id: UUID) {
        let waiters = state.withLock { state in
            state.sections[keychainService]?.remove(id)
            guard state.sections[keychainService]?.isEmpty == true else {
                return [CheckedContinuation<Void, Never>]()
            }
            state.sections[keychainService] = nil
            return Array((state.waiters.removeValue(forKey: keychainService) ?? [:]).values)
        }
        for waiter in waiters { waiter.resume() }
    }
}
